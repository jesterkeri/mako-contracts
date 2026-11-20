// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MakoFunder} from "../src/MakoFunder.sol";

contract Rejecter {
    receive() external payable {
        revert("no");
    }
}

contract MakoFunderTest is Test {
    MakoFunder f;
    address owner = address(this);
    address stranger = address(0xBAD);
    address k1 = address(0x1001);
    address k2 = address(0x1002);
    address k3 = address(0x1003);
    address k4 = address(0x1004);
    address k5 = address(0x1005);
    address sink = address(0x5111);
    uint256 constant CAP = 10 ether;
    uint256 constant D0 = 20_000; // deployment day

    event TopUp(address indexed recipient, uint256 sent, uint256 day, uint256 r);
    event KeyAdded(address indexed key);
    event KeyRetired(address indexed key);
    event CapSet(uint256 cap);
    event Withdrawn(address indexed to, uint256 amount);
    event ClosedTo(address indexed to, uint256 amount);
    event Deposit(address indexed from, uint256 amount);

    function setUp() public {
        vm.warp(D0 * 1 days + 12 hours);
        vm.roll(100);
        f = new MakoFunder(CAP);
        vm.deal(address(f), 100 ether);
        f.addKey(k1);
    }

    // helpers ---------------------------------------------------------------------------------
    function _nextDay(uint256 secondsIntoDay) internal returns (uint256 day) {
        day = vm.getBlockTimestamp() / 1 days + 1;
        vm.warp(day * 1 days + secondsIntoDay);
        vm.roll(vm.getBlockNumber() + 5);
    }

    function _top(uint256 amount) internal returns (uint256 day) {
        day = _nextDay(8 hours);
        f.topUp(vm.getBlockNumber() - 1, amount, day);
    }

    // construction ----------------------------------------------------------------------------
    function test_constructor() public view {
        assertEq(f.owner(), owner);
        assertEq(f.cap(), CAP);
        assertEq(f.lastDay(), D0);
        assertEq(f.lastTopUpBlock(), 0);
        assertFalse(f.closed());
        assertEq(f.recipient(), k1);
    }

    function test_firstTopUpOnDeploymentDayReverts() public {
        vm.roll(vm.getBlockNumber() + 1);
        vm.expectRevert(MakoFunder.SameDay.selector);
        f.topUp(vm.getBlockNumber() - 1, 1 ether, D0);
    }

    // owner only ------------------------------------------------------------------------------
    function test_everyFunctionIsOwnerOnly() public {
        vm.startPrank(stranger);
        vm.expectRevert(MakoFunder.NotOwner.selector);
        f.topUp(0, 1, 1);
        vm.expectRevert(MakoFunder.NotOwner.selector);
        f.addKey(k2);
        vm.expectRevert(MakoFunder.NotOwner.selector);
        f.retireKey(k1);
        vm.expectRevert(MakoFunder.NotOwner.selector);
        f.setCap(1);
        vm.expectRevert(MakoFunder.NotOwner.selector);
        f.withdraw(stranger, 1);
        vm.expectRevert(MakoFunder.NotOwner.selector);
        f.close(stranger);
        vm.stopPrank();
    }

    function test_ownerCheckBeatsEveryOtherCheck() public {
        // a stranger calling topUp with bad everything still gets NotOwner, even when closed.
        f.close(sink);
        vm.prank(stranger);
        vm.expectRevert(MakoFunder.NotOwner.selector);
        f.topUp(0, 0, 0);
    }

    function test_receiveAcceptsAnyone() public {
        vm.deal(stranger, 1 ether);
        vm.expectEmit(true, false, false, true);
        emit Deposit(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(f).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(f).balance, 101 ether);
    }

    // keys ------------------------------------------------------------------------------------
    function test_addKeyRules() public {
        vm.expectRevert(MakoFunder.ZeroAddress.selector);
        f.addKey(address(0));
        vm.expectRevert(MakoFunder.KeyUsed.selector);
        f.addKey(k1);
        vm.expectEmit(true, false, false, false);
        emit KeyAdded(k2);
        f.addKey(k2);
        assertEq(f.recipient(), k2);
        f.addKey(k3);
        f.addKey(k4);
        assertEq(f.keys().length, 4);
        vm.expectRevert(MakoFunder.TooManyKeys.selector);
        f.addKey(k5);
    }

    function test_retiredKeyCannotBeListedAgain() public {
        f.retireKey(k1);
        vm.expectRevert(MakoFunder.KeyUsed.selector);
        f.addKey(k1);
    }

    function test_retireFreesASlot() public {
        f.addKey(k2);
        f.addKey(k3);
        f.addKey(k4);
        f.retireKey(k1);
        f.addKey(k5);
        assertEq(f.keys().length, 4);
        assertEq(f.recipient(), k5);
    }

    function test_retireUnlistedReverts() public {
        vm.expectRevert(MakoFunder.NotListed.selector);
        f.retireKey(k2);
        f.retireKey(k1);
        vm.expectRevert(MakoFunder.NotListed.selector);
        f.retireKey(k1);
    }

    function test_retireRecipientLeavesNoRecipientUntilAddKey() public {
        vm.expectEmit(true, false, false, false);
        emit KeyRetired(k1);
        f.retireKey(k1);
        assertEq(f.recipient(), address(0));
        uint256 day = _nextDay(0);
        vm.expectRevert(MakoFunder.NoRecipient.selector);
        f.topUp(vm.getBlockNumber() - 1, 1, day);
        f.addKey(k2);
        f.topUp(vm.getBlockNumber() - 1, 1 ether, day);
        assertEq(k2.balance, 1 ether);
    }

    function test_retireNonRecipientKeepsRecipient() public {
        f.addKey(k2);
        f.retireKey(k1);
        assertEq(f.recipient(), k2);
        assertEq(f.keys().length, 1);
    }

    function test_retiredKeyLeavesTheSum() public {
        f.addKey(k2);
        vm.deal(k1, 9 ether);
        f.retireKey(k1);
        assertEq(f.keysBalance(), 0);
        _top(100 ether);
        assertEq(k2.balance, CAP);
    }

    // topUp ceiling ---------------------------------------------------------------------------
    function test_topUpToCapWithOneTwoAndFourKeys() public {
        vm.deal(k1, 3 ether);
        uint256 day = _nextDay(0);
        f.topUp(vm.getBlockNumber() - 1, CAP - 3 ether, day);
        assertEq(f.keysBalance(), CAP);

        f.addKey(k2);
        vm.deal(k1, 1 ether);
        vm.deal(k2, 2 ether);
        day = _nextDay(0);
        f.topUp(vm.getBlockNumber() - 1, CAP - 3 ether, day);
        assertEq(f.keysBalance(), CAP);

        f.addKey(k3);
        f.addKey(k4);
        vm.deal(k1, 1 ether);
        vm.deal(k2, 1 ether);
        vm.deal(k3, 1 ether);
        vm.deal(k4, 1 ether);
        day = _nextDay(0);
        f.topUp(vm.getBlockNumber() - 1, CAP - 4 ether, day);
        assertEq(f.keysBalance(), CAP);
        assertEq(k4.balance, 7 ether);
    }

    function test_smallerOfRuleKeySpentAfterReconciliation() public {
        // helper saw 3 ether at r and asked for 7; the key then spent 2 more: sum 1, room 9, sends 7.
        vm.deal(k1, 3 ether);
        uint256 day = _nextDay(0);
        uint256 r = vm.getBlockNumber() - 1;
        vm.deal(k1, 1 ether);
        f.topUp(r, 7 ether, day);
        assertEq(k1.balance, 8 ether);
        assertLt(f.keysBalance(), CAP);
    }

    function test_keySumRaisedAfterReconciliationCapsAmount() public {
        // helper figure 7, but a stranger deposited 5 into the key: room 5, sends 5, sum exactly cap.
        vm.deal(k1, 3 ether);
        uint256 day = _nextDay(0);
        uint256 r = vm.getBlockNumber() - 1;
        vm.deal(k1, 8 ether);
        f.topUp(r, 7 ether, day);
        assertEq(k1.balance, CAP);
    }

    function test_strangerDepositLowersNextTopUp() public {
        vm.deal(k1, 4 ether);
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = k1.call{value: 1 ether}("");
        assertTrue(ok);
        _top(100 ether);
        assertEq(k1.balance, CAP);
    }

    function test_atCapReverts() public {
        vm.deal(k1, CAP);
        uint256 day = _nextDay(0);
        vm.expectRevert(MakoFunder.AtCap.selector);
        f.topUp(vm.getBlockNumber() - 1, 1, day);
        vm.deal(k1, CAP + 1);
        vm.expectRevert(MakoFunder.AtCap.selector);
        f.topUp(vm.getBlockNumber() - 1, 1, day);
        vm.deal(k1, CAP - 1);
        f.topUp(vm.getBlockNumber() - 1, 5, day); // sum just below cap succeeds, sends 1
        assertEq(k1.balance, CAP);
    }

    function test_atCapAcrossKeysCountsAllKeys() public {
        f.addKey(k2);
        vm.deal(k1, 6 ether);
        vm.deal(k2, 4 ether);
        uint256 day = _nextDay(0);
        vm.expectRevert(MakoFunder.AtCap.selector);
        f.topUp(vm.getBlockNumber() - 1, 1, day);
    }

    function test_underfundedReverts() public {
        f.withdraw(sink, 100 ether - 1 ether);
        uint256 day = _nextDay(0);
        vm.expectRevert(MakoFunder.Underfunded.selector);
        f.topUp(vm.getBlockNumber() - 1, 2 ether, day);
        f.topUp(vm.getBlockNumber() - 1, 1 ether, day); // exactly what it holds succeeds
        assertEq(address(f).balance, 0);
    }

    function test_underfundedUsesSentNotAmount() public {
        // amount larger than holdings but room smaller: holds enough for what it sends.
        vm.deal(k1, 9 ether);
        f.withdraw(sink, 100 ether - 1 ether);
        uint256 day = _nextDay(0);
        f.topUp(vm.getBlockNumber() - 1, 50 ether, day);
        assertEq(k1.balance, CAP);
    }

    function test_setCapAppliesToNextTopUp() public {
        _top(100 ether);
        assertEq(k1.balance, CAP);
        f.setCap(4 ether);
        assertEq(k1.balance, CAP); // already-made top-up untouched
        vm.deal(k1, 0);
        uint256 day = _nextDay(0);
        f.topUp(vm.getBlockNumber() - 1, 100 ether, day);
        assertEq(k1.balance, 4 ether);
    }

    function test_setCapCutLeavesKeysAtEarlierValueThenAtCap() public {
        _top(100 ether); // keys hold 10
        f.setCap(5 ether);
        uint256 day = _nextDay(0);
        vm.expectRevert(MakoFunder.AtCap.selector);
        f.topUp(vm.getBlockNumber() - 1, 1, day);
        vm.deal(k1, 2 ether);
        f.topUp(vm.getBlockNumber() - 1, 100 ether, day);
        assertEq(k1.balance, 5 ether);
    }

    function test_setCapRaisedAppliesNextTopUp() public {
        f.setCap(30 ether);
        _top(100 ether);
        assertEq(k1.balance, 30 ether);
    }

    function test_setCapEmitsAndZeroCapMeansAtCap() public {
        vm.expectEmit(false, false, false, true);
        emit CapSet(0);
        f.setCap(0);
        uint256 day = _nextDay(0);
        vm.expectRevert(MakoFunder.AtCap.selector);
        f.topUp(vm.getBlockNumber() - 1, 1, day);
    }

    // day rules -------------------------------------------------------------------------------
    function test_wrongDayReverts() public {
        uint256 day = _nextDay(100);
        vm.expectRevert(MakoFunder.WrongDay.selector);
        f.topUp(vm.getBlockNumber() - 1, 1 ether, day + 1);
        vm.expectRevert(MakoFunder.WrongDay.selector);
        f.topUp(vm.getBlockNumber() - 1, 1 ether, day - 1);
        f.topUp(vm.getBlockNumber() - 1, 1 ether, day);
    }

    function test_wrongDayBoundaryExact() public {
        uint256 day = vm.getBlockTimestamp() / 1 days + 1;
        vm.warp(day * 1 days - 1); // last second of the previous day
        vm.roll(vm.getBlockNumber() + 1);
        vm.expectRevert(MakoFunder.WrongDay.selector);
        f.topUp(vm.getBlockNumber() - 1, 1, day);
        vm.warp(day * 1 days);
        f.topUp(vm.getBlockNumber() - 1, 1 ether, day);
    }

    function test_secondTopUpSameDayReverts_midnightEdges() public {
        uint256 day = _nextDay(0); // 00:00:00
        f.topUp(vm.getBlockNumber() - 1, 1 ether, day);
        vm.warp(day * 1 days + 1 days - 1); // 23:59:59
        vm.roll(vm.getBlockNumber() + 1);
        vm.expectRevert(MakoFunder.SameDay.selector);
        f.topUp(vm.getBlockNumber() - 1, 1 ether, day);
    }

    function test_topUpLastSecondThenFirstSecondNextDayBothSucceed() public {
        uint256 day = vm.getBlockTimestamp() / 1 days + 1;
        vm.warp(day * 1 days + 1 days - 1);
        vm.roll(vm.getBlockNumber() + 2);
        f.topUp(vm.getBlockNumber() - 1, 1 ether, day);
        vm.warp((day + 1) * 1 days);
        vm.roll(vm.getBlockNumber() + 1);
        f.topUp(vm.getBlockNumber() - 1, 1 ether, day + 1);
        assertEq(k1.balance, 2 ether);
        assertEq(f.lastDay(), day + 1);
    }

    function test_dayEqualToLastDayReverts_pastDayWrongDayFirst() public {
        _top(1 ether);
        // deployed-day style: day <= lastDay
        vm.roll(vm.getBlockNumber() + 1);
        uint256 last = f.lastDay();
        vm.expectRevert(MakoFunder.SameDay.selector);
        f.topUp(vm.getBlockNumber() - 1, 1, last);
    }

    // block rules -----------------------------------------------------------------------------
    function test_badBlock() public {
        uint256 day = _nextDay(0);
        vm.expectRevert(MakoFunder.BadBlock.selector);
        f.topUp(vm.getBlockNumber(), 1, day); // r == current block
        vm.expectRevert(MakoFunder.BadBlock.selector);
        f.topUp(vm.getBlockNumber() + 1, 1, day);
        f.topUp(vm.getBlockNumber() - 1, 1 ether, day);
        assertEq(f.lastTopUpBlock(), vm.getBlockNumber());
    }

    function test_badBlockBeforePreviousTopUp() public {
        uint256 day = _nextDay(0);
        f.topUp(vm.getBlockNumber() - 1, 1 ether, day);
        uint256 prev = f.lastTopUpBlock();
        day = _nextDay(0);
        vm.expectRevert(MakoFunder.BadBlock.selector);
        f.topUp(prev - 1, 1, day);
        f.topUp(prev, 1 ether, day); // r == lastTopUpBlock allowed
    }

    function test_rZeroAllowedFirstTime() public {
        uint256 day = _nextDay(0);
        f.topUp(0, 1 ether, day);
    }

    // send failures, close, withdraw ------------------------------------------------------------
    function test_sendFailedChangesNoState() public {
        Rejecter rj = new Rejecter();
        f.retireKey(k1);
        f.addKey(address(rj));
        uint256 day = _nextDay(0);
        vm.expectRevert(MakoFunder.SendFailed.selector);
        f.topUp(vm.getBlockNumber() - 1, 1 ether, day);
        assertEq(f.lastDay(), D0);
        assertEq(f.lastTopUpBlock(), 0);
        assertEq(address(f).balance, 100 ether);
    }

    function test_topUpEmitsEvent() public {
        uint256 day = _nextDay(0);
        uint256 r = vm.getBlockNumber() - 1;
        vm.expectEmit(true, false, false, true);
        emit TopUp(k1, 4 ether, day, r);
        f.topUp(r, 4 ether, day);
    }

    function test_topUpEventReportsSentNotAmount() public {
        vm.deal(k1, 8 ether);
        uint256 day = _nextDay(0);
        uint256 r = vm.getBlockNumber() - 1;
        vm.expectEmit(true, false, false, true);
        emit TopUp(k1, 2 ether, day, r);
        f.topUp(r, 7 ether, day);
    }

    function test_withdraw() public {
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(sink, 3 ether);
        f.withdraw(sink, 3 ether);
        assertEq(sink.balance, 3 ether);
        assertEq(address(f).balance, 97 ether);
        vm.expectRevert(MakoFunder.Underfunded.selector);
        f.withdraw(sink, 97 ether + 1);
        vm.expectRevert(MakoFunder.ZeroAddress.selector);
        f.withdraw(address(0), 1);
        f.withdraw(sink, 97 ether);
        assertEq(address(f).balance, 0);
    }

    function test_withdrawToRejecterReverts() public {
        Rejecter rj = new Rejecter();
        vm.expectRevert(MakoFunder.SendFailed.selector);
        f.withdraw(address(rj), 1 ether);
    }

    function test_closeSendsAllAndBlocksTopUp() public {
        vm.expectEmit(true, false, false, true);
        emit ClosedTo(sink, 100 ether);
        f.close(sink);
        assertEq(sink.balance, 100 ether);
        assertEq(address(f).balance, 0);
        assertTrue(f.closed());
        uint256 day = _nextDay(0);
        vm.expectRevert(MakoFunder.Closed.selector);
        f.topUp(vm.getBlockNumber() - 1, 1, day);
    }

    function test_closeZeroAddressAndRejecter() public {
        vm.expectRevert(MakoFunder.ZeroAddress.selector);
        f.close(address(0));
        Rejecter rj = new Rejecter();
        vm.expectRevert(MakoFunder.SendFailed.selector);
        f.close(address(rj));
        assertFalse(f.closed()); // revert undid the flag
    }

    function test_afterCloseOwnerCanStillWithdrawLaterDeposits() public {
        f.close(sink);
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(f).call{value: 1 ether}("");
        assertTrue(ok);
        f.withdraw(sink, 1 ether);
        assertEq(address(f).balance, 0);
    }

    function test_keyManagementStillWorksAfterClose() public {
        f.close(sink);
        f.addKey(k2);
        f.setCap(1);
        f.retireKey(k2);
    }

    // fuzz ------------------------------------------------------------------------------------
    function testFuzz_topUpNeverExceedsAmountOrRoom(uint96 bal, uint96 later, uint96 amount, uint96 capv) public {
        f.setCap(capv);
        vm.deal(k1, bal);
        uint256 day = _nextDay(0);
        uint256 r = vm.getBlockNumber() - 1;
        vm.deal(k1, later);
        vm.deal(address(f), 1e30);
        uint256 before = k1.balance;
        if (later >= capv) {
            vm.expectRevert(MakoFunder.AtCap.selector);
            f.topUp(r, amount, day);
            return;
        }
        f.topUp(r, amount, day);
        uint256 sent = k1.balance - before;
        assertLe(sent, amount);
        assertLe(sent, uint256(capv) - later);
        assertLe(k1.balance, capv);
        assertEq(sent, amount < uint256(capv) - later ? amount : uint256(capv) - later);
    }

    function testFuzz_onlyOwnerCanCall(address caller, uint256 a, uint256 b, uint256 c) public {
        vm.assume(caller != owner);
        vm.startPrank(caller);
        vm.expectRevert(MakoFunder.NotOwner.selector);
        f.topUp(a, b, c);
        vm.expectRevert(MakoFunder.NotOwner.selector);
        f.addKey(address(uint160(a)));
        vm.expectRevert(MakoFunder.NotOwner.selector);
        f.retireKey(address(uint160(a)));
        vm.expectRevert(MakoFunder.NotOwner.selector);
        f.setCap(a);
        vm.expectRevert(MakoFunder.NotOwner.selector);
        f.withdraw(caller, b);
        vm.expectRevert(MakoFunder.NotOwner.selector);
        f.close(caller);
        vm.stopPrank();
    }

    function testFuzz_oneTopUpPerDay(uint32 t0, uint32 dt) public {
        uint256 day = uint256(t0 % 5000) + D0 + 1;
        vm.warp(day * 1 days + (uint256(dt) % 1 days));
        vm.roll(vm.getBlockNumber() + 2);
        f.topUp(vm.getBlockNumber() - 1, 1 ether, day);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(day * 1 days + 1 days - 1);
        vm.expectRevert(MakoFunder.SameDay.selector);
        f.topUp(vm.getBlockNumber() - 1, 1 ether, day);
        // next UTC day works
        vm.warp((day + 1) * 1 days);
        f.topUp(vm.getBlockNumber() - 1, 1 ether, day + 1);
    }

    function testFuzz_wrongDay(uint256 day) public {
        vm.assume(day != vm.getBlockTimestamp() / 1 days);
        vm.roll(vm.getBlockNumber() + 1);
        vm.expectRevert(MakoFunder.WrongDay.selector);
        f.topUp(vm.getBlockNumber() - 1, 1, day);
    }

    function testFuzz_withdrawBounded(uint96 dep, uint96 amt) public {
        vm.deal(address(f), dep);
        if (amt > dep) {
            vm.expectRevert(MakoFunder.Underfunded.selector);
            f.withdraw(sink, amt);
        } else {
            f.withdraw(sink, amt);
            assertEq(address(f).balance, uint256(dep) - amt);
        }
    }
}
