// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
// Code under attack: src/MakoFunder.sol at commit fef8dec (branch feat/mako-funder), verbatim.
import {MakoFunder} from "../../src/MakoFunder.sol";

/// Adversary pass on MakoFunder (plan OFFCHAIN_MATCHING_PLAN.md section 6.3). Every test here passes
/// against fef8dec: each is an attack the contract's own guards stopped.

/// Owner and recipient in one contract: tries to re-enter topUp from its own receive.
contract ReenterOwner {
    MakoFunder public f;
    uint256 public day;
    uint256 public reenterBlock;
    bool public reenterReverted;
    bytes4 public reenterSelector;
    uint256 public received;

    function deploy(uint256 cap) external {
        f = new MakoFunder(cap);
    }

    function arm(uint256 day_, uint256 blk) external {
        day = day_;
        reenterBlock = blk;
    }

    function go(uint256 r, uint256 amount, uint256 day_) external {
        f.topUp(r, amount, day_);
    }

    function add(address k) external {
        f.addKey(k);
    }

    receive() external payable {
        if (msg.sender == address(f)) {
            received += msg.value;
            try f.topUp(reenterBlock, type(uint256).max, day) {}
            catch (bytes memory err) {
                reenterReverted = true;
                if (err.length >= 4) reenterSelector = bytes4(err);
            }
        }
    }
}

/// A listed key that forwards what it receives to another listed key.
contract Forwarder {
    address payable public to;

    constructor(address payable to_) {
        to = to_;
    }

    receive() external payable {
        to.transfer(msg.value);
    }
}

/// Recipient that burns all gas.
contract GasBurner {
    receive() external payable {
        while (true) {}
    }
}

contract Bomb {
    constructor(address payable t) payable {
        selfdestruct(t);
    }
}

contract Rejecter {
    receive() external payable {
        revert("no");
    }
}

contract MakoFunderAdversaryTest is Test {
    MakoFunder f;
    address k1 = address(0x1001);
    address k2 = address(0x1002);
    address k3 = address(0x1003);
    address k4 = address(0x1004);
    address k5 = address(0x1005);
    uint256 constant CAP = 10 ether;
    uint256 constant D0 = 20_000;

    function setUp() public {
        vm.warp(D0 * 1 days + 12 hours);
        vm.roll(100);
        f = new MakoFunder(CAP);
        vm.deal(address(f), 100 ether);
        f.addKey(k1);
    }

    function _day(uint256 d, uint256 secs) internal {
        vm.warp(d * 1 days + secs);
        vm.roll(vm.getBlockNumber() + 5);
    }

    function test_reenterTopUpFromRecipient() public {
        ReenterOwner ro = new ReenterOwner();
        ro.deploy(CAP);
        MakoFunder g = ro.f();
        vm.deal(address(g), 100 ether);
        ro.add(address(ro));
        uint256 d = D0 + 1;
        _day(d, 100);
        ro.arm(d, vm.getBlockNumber() - 1);
        ro.go(vm.getBlockNumber() - 1, 3 ether, d);
        assertEq(ro.received(), 3 ether, "one send only");
        assertTrue(ro.reenterReverted());
        assertEq(ro.reenterSelector(), MakoFunder.SameDay.selector);
        assertEq(address(g).balance, 97 ether);
    }

    function test_forwardingKeyKeepsCeiling() public {
        MakoFunder g = new MakoFunder(CAP);
        vm.deal(address(g), 100 ether);
        g.addKey(k2);
        Forwarder fw = new Forwarder(payable(k2));
        g.addKey(address(fw));
        uint256 d = D0 + 1;
        _day(d, 100);
        g.topUp(vm.getBlockNumber() - 1, type(uint256).max, d);
        assertEq(g.keysBalance(), CAP);
        assertEq(k2.balance, CAP);
        assertEq(address(fw).balance, 0);
    }

    function test_gasBurnerRecipientBlocksOnlyThatTopUp() public {
        GasBurner gb = new GasBurner();
        f.addKey(address(gb));
        uint256 d = D0 + 1;
        _day(d, 100);
        vm.expectRevert();
        f.topUp(vm.getBlockNumber() - 1, 1 ether, d);
        assertEq(f.lastDay(), D0);
        assertEq(f.lastTopUpBlock(), 0);
        assertEq(address(f).balance, 100 ether);
        f.retireKey(address(gb));
        f.addKey(k2);
        f.topUp(vm.getBlockNumber() - 1, 1 ether, d);
        assertEq(k2.balance, 1 ether);
    }

    function test_forcedEthIntoKeyShrinksTopUp() public {
        new Bomb{value: 4 ether}(payable(k1));
        uint256 d = D0 + 1;
        _day(d, 100);
        f.topUp(vm.getBlockNumber() - 1, type(uint256).max, d);
        assertEq(k1.balance, CAP);
    }

    function test_forcedEthIntoKeyAtCapReverts() public {
        new Bomb{value: CAP}(payable(k1));
        uint256 d = D0 + 1;
        _day(d, 100);
        vm.expectRevert(MakoFunder.AtCap.selector);
        f.topUp(vm.getBlockNumber() - 1, 1, d);
    }

    function test_forcedEthIntoFunderWithdrawable() public {
        new Bomb{value: 7 ether}(payable(address(f)));
        assertEq(address(f).balance, 107 ether);
        f.withdraw(address(0xBEEF), 107 ether);
        assertEq(address(f).balance, 0);
        assertEq(address(0xBEEF).balance, 107 ether);
    }

    function test_dayBoundaries() public {
        vm.warp(D0 * 1 days + 86399);
        vm.roll(200);
        vm.expectRevert(MakoFunder.SameDay.selector);
        f.topUp(150, 1, D0);
        vm.warp((D0 + 1) * 1 days);
        vm.roll(201);
        f.topUp(150, 1 ether, D0 + 1);
        vm.warp((D0 + 1) * 1 days + 86399);
        vm.roll(202);
        vm.expectRevert(MakoFunder.SameDay.selector);
        f.topUp(201, 1, D0 + 1);
        vm.warp((D0 + 2) * 1 days);
        vm.roll(203);
        vm.expectRevert(MakoFunder.WrongDay.selector);
        f.topUp(202, 1, D0 + 1);
        vm.expectRevert(MakoFunder.WrongDay.selector);
        f.topUp(202, 1, D0 + 3);
    }

    function test_rEdges() public {
        uint256 d = D0 + 1;
        _day(d, 100);
        uint256 b = vm.getBlockNumber();
        vm.expectRevert(MakoFunder.BadBlock.selector);
        f.topUp(b, 1, d);
        vm.expectRevert(MakoFunder.BadBlock.selector);
        f.topUp(type(uint256).max, 1, d);
        f.topUp(b - 1, 1 ether, d);
        d++;
        _day(d, 100);
        vm.expectRevert(MakoFunder.BadBlock.selector);
        f.topUp(b - 1, 1, d);
        f.topUp(b, 1 ether, d);
    }

    function test_setCapEdges() public {
        uint256 d = D0 + 1;
        _day(d, 100);
        f.topUp(vm.getBlockNumber() - 1, type(uint256).max, d);
        f.setCap(0);
        d++;
        _day(d, 100);
        vm.expectRevert(MakoFunder.AtCap.selector);
        f.topUp(vm.getBlockNumber() - 1, 1, d);
        f.setCap(CAP / 2);
        vm.expectRevert(MakoFunder.AtCap.selector);
        f.topUp(vm.getBlockNumber() - 1, 1, d);
        vm.deal(k1, 0);
        f.setCap(3 ether);
        f.topUp(vm.getBlockNumber() - 1, type(uint256).max, d);
        assertEq(k1.balance, 3 ether);
    }

    function test_keyCapAndRetire() public {
        f.addKey(k2);
        f.addKey(k3);
        f.addKey(k4);
        vm.expectRevert(MakoFunder.TooManyKeys.selector);
        f.addKey(k5);
        f.retireKey(k2);
        assertEq(f.recipient(), k4);
        vm.expectRevert(MakoFunder.KeyUsed.selector);
        f.addKey(k2);
        f.addKey(k5);
        assertEq(f.keys().length, 4);
        vm.expectRevert(MakoFunder.NotListed.selector);
        f.retireKey(k2);
        f.retireKey(k5);
        assertEq(f.recipient(), address(0));
        uint256 d = D0 + 1;
        _day(d, 100);
        vm.expectRevert(MakoFunder.NoRecipient.selector);
        f.topUp(vm.getBlockNumber() - 1, 1, d);
        f.retireKey(k1);
        f.retireKey(k3);
        f.retireKey(k4);
        assertEq(f.keysBalance(), 0);
        assertEq(f.keys().length, 0);
        vm.expectRevert(MakoFunder.KeyUsed.selector);
        f.addKey(k1);
    }

    function test_sumCoversAllListedKeys() public {
        f.addKey(k2);
        vm.deal(k1, 6 ether);
        uint256 d = D0 + 1;
        _day(d, 100);
        f.topUp(vm.getBlockNumber() - 1, type(uint256).max, d);
        assertEq(k2.balance, 4 ether);
        assertEq(f.keysBalance(), CAP);
    }

    function test_closeThenReceiveWithdraw() public {
        f.close(address(0xCAFE));
        assertEq(address(f).balance, 0);
        (bool ok,) = address(f).call{value: 1 ether}("");
        assertTrue(ok);
        f.withdraw(address(0xCAFE), 1 ether);
        assertEq(address(f).balance, 0);
        uint256 d = D0 + 1;
        _day(d, 100);
        vm.expectRevert(MakoFunder.Closed.selector);
        f.topUp(vm.getBlockNumber() - 1, 1, d);
        MakoFunder g = new MakoFunder(CAP);
        vm.deal(address(g), 1 ether);
        Rejecter rj = new Rejecter();
        vm.expectRevert(MakoFunder.SendFailed.selector);
        g.close(address(rj));
        assertFalse(g.closed());
    }

    function test_onlyOwner() public {
        address[3] memory callers = [k1, address(f), address(0xBAD)];
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(callers[i]);
            vm.expectRevert(MakoFunder.NotOwner.selector);
            f.topUp(0, 1, 1);
            vm.expectRevert(MakoFunder.NotOwner.selector);
            f.addKey(k5);
            vm.expectRevert(MakoFunder.NotOwner.selector);
            f.retireKey(k1);
            vm.expectRevert(MakoFunder.NotOwner.selector);
            f.setCap(1);
            vm.expectRevert(MakoFunder.NotOwner.selector);
            f.withdraw(callers[i], 1);
            vm.expectRevert(MakoFunder.NotOwner.selector);
            f.close(callers[i]);
            vm.stopPrank();
        }
    }

    function test_funderAsKeyDoesNotLockDeposit() public {
        f.addKey(address(f));
        uint256 d = D0 + 1;
        _day(d, 100);
        vm.expectRevert(MakoFunder.AtCap.selector);
        f.topUp(vm.getBlockNumber() - 1, 1, d);
        f.withdraw(address(0xBEEF), 100 ether);
        assertEq(address(0xBEEF).balance, 100 ether);
    }

    function testFuzz_ceiling(uint96 spent, uint96 stranger, uint96 amount, uint96 cap) public {
        f.setCap(cap);
        f.addKey(k2);
        vm.deal(k1, uint256(stranger));
        vm.deal(k2, uint256(spent));
        uint256 before_ = f.keysBalance();
        uint256 d = D0 + 1;
        _day(d, 100);
        try f.topUp(vm.getBlockNumber() - 1, amount, d) {
            assertLe(f.keysBalance(), cap, "above cap after topUp");
            assertLe(f.keysBalance() - before_, amount);
        } catch {}
    }
}
