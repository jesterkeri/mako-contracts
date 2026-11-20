// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Scene} from "./Scene.sol";
import {MakoOutcomeExchangeV1 as X} from "../../src/MakoOutcomeExchangeV1.sol";
import {
    MockUSDC,
    NoReturnUSDC,
    FalseReturnUSDC,
    RevertingUSDC,
    FeeOnTransferUSDC,
    MalformedReturnUSDC,
    OvershootUSDC,
    ShortTransferUSDC,
    ReentrantUSDC
} from "../mocks/TokenMocks.sol";

/// @notice Roles and the operator's powers (plan sections 3.3 and 3.4: O4, O5, O8), markets, cash, complete sets,
/// resolution and the treasury (MAKO_POOLS_PLAN section 9.1: X6, X8, X10, X11, X12, X16, X17, X19).
contract AdminTest is Scene {
    address internal stranger = makeAddr("stranger");

    function _e(bytes4 sel) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(sel);
    }

    // ------------------------------------------------------------------------------------------------ constructor, constants
    function test_constructor_roles_andImmutables() public view {
        assertEq(ex.admin(), address(this));
        assertEq(ex.resolver(), address(this));
        assertEq(ex.TREASURY(), treasury);
        assertEq(address(ex.USDC()), address(usd));
        assertEq(ex.MAX_MAKERS(), 10);
        assertEq(ex.MAX_SIG_LEN(), 195);
        assertEq(ex.SIG_GAS(), 100_000);
        assertEq(ex.MAX_FEE_RATE(), 700);
        assertEq(ex.VETO_PERIOD(), 24 hours);
        assertEq(ex.BACKSTOP_DELAY(), 7 days);
    }

    // ------------------------------------------------------------------------------------------------ createMarket
    function test_createMarket_validation() public {
        uint64 close = uint64(block.timestamp + 1 days);
        uint64 dl = uint64(block.timestamp + 2 days);
        vm.expectRevert(X.BadOption.selector);
        ex.createMarket(1, 0, close, dl, 1e9, bytes32(0));
        vm.expectRevert(X.BadOption.selector);
        ex.createMarket(12, 0, close, dl, 1e9, bytes32(0));
        vm.expectRevert(X.BadFee.selector);
        ex.createMarket(2, 701, close, dl, 1e9, bytes32(0));
        vm.expectRevert(X.BadMarket.selector);
        ex.createMarket(2, 0, uint64(block.timestamp), dl, 1e9, bytes32(0)); // not in the future
        vm.expectRevert(X.BadMarket.selector);
        ex.createMarket(2, 0, close, close - 1, 1e9, bytes32(0)); // deadline before close
        vm.expectRevert(X.BadMarket.selector);
        ex.createMarket(2, 0, close, dl, 0, bytes32(0)); // a zero cap
        // boundaries that are valid
        ex.createMarket(2, 700, close, close, 1, bytes32(0));
        ex.createMarket(11, 0, close, dl, 1e9, bytes32(uint256(5)));
        assertEq(ex.marketOf(ex.marketCount()).rulesHash, bytes32(uint256(5)));
    }

    function test_createMarket_adminOnly_andNotWhilePaused() public {
        vm.prank(stranger);
        vm.expectRevert(X.NotAdmin.selector);
        ex.createMarket(2, 0, uint64(block.timestamp + 1 days), uint64(block.timestamp + 2 days), 1e9, bytes32(0));
        vm.prank(operator);
        vm.expectRevert(X.NotAdmin.selector);
        ex.createMarket(2, 0, uint64(block.timestamp + 1 days), uint64(block.timestamp + 2 days), 1e9, bytes32(0));
        ex.setPaused(true);
        vm.expectRevert(X.Paused.selector);
        ex.createMarket(2, 0, uint64(block.timestamp + 1 days), uint64(block.timestamp + 2 days), 1e9, bytes32(0));
    }

    function test_createMarket_marketTermsAreStored_X12() public view {
        X.Market memory mk = ex.marketOf(m);
        assertEq(mk.nOptions, 3);
        assertEq(mk.feeRate, FEE);
        assertEq(mk.status, 1);
        assertEq(mk.positionCap, CAP);
        assertEq(ex.marketCount(), 1);
    }

    // ------------------------------------------------------------------------------------------------ roles: O4, O8
    function test_matchOrders_operatorOnly_O4() public {
        Call memory c = _dBuy1(10e6);
        address[4] memory nots = [stranger, address(this), ex.resolver(), treasury]; // admin, resolver, treasury are no operators
        for (uint256 i; i < nots.length; ++i) {
            vm.prank(nots[i]);
            vm.expectRevert(X.NotOperator.selector);
            ex.matchOrders(c.t, c.ts, c.ms, c.mss, c.fs, c.tf);
        }
        // a removed operator is no operator
        ex.setOperator(operator, false);
        vm.prank(operator);
        vm.expectRevert(X.NotOperator.selector);
        ex.matchOrders(c.t, c.ts, c.ms, c.mss, c.fs, c.tf);
        ex.setOperator(operator, true);
        _send(c);
    }

    function test_setOperator_adminOnly_andEvent() public {
        vm.prank(stranger);
        vm.expectRevert(X.NotAdmin.selector);
        ex.setOperator(stranger, true);
        vm.prank(operator);
        vm.expectRevert(X.NotAdmin.selector);
        ex.setOperator(stranger, true);
        vm.expectEmit(true, false, false, true, address(ex));
        emit X.OperatorSet(stranger, true);
        ex.setOperator(stranger, true);
        assertTrue(ex.isOperator(stranger));
    }

    function test_O8_setOperator_refusesAdmin_pendingAdmin_resolver_treasury() public {
        vm.expectRevert(X.RoleConflict.selector);
        ex.setOperator(address(this), true); // admin
        ex.transferAdmin(stranger);
        vm.expectRevert(X.RoleConflict.selector);
        ex.setOperator(stranger, true); // pending admin
        address r = makeAddr("resolver");
        ex.setResolver(r);
        vm.expectRevert(X.RoleConflict.selector);
        ex.setOperator(r, true); // resolver
        vm.expectRevert(X.RoleConflict.selector);
        ex.setOperator(treasury, true); // TREASURY
        // removal is always allowed, even for a role holder
        ex.setOperator(r, false);
    }

    function test_O8_setResolver_andTransferAdmin_refuseAnOperator() public {
        vm.expectRevert(X.RoleConflict.selector);
        ex.setResolver(operator);
        vm.expectRevert(X.RoleConflict.selector);
        ex.transferAdmin(operator);
        // so an operator can never be promoted to either role
        ex.setOperator(operator, false);
        ex.setResolver(operator);
        assertEq(ex.resolver(), operator);
    }

    function test_O8_operatorCanCallNothingElsePrivileged() public {
        vm.startPrank(operator);
        vm.expectRevert(X.NotAdmin.selector);
        ex.setPaused(true);
        vm.expectRevert(X.NotAdmin.selector);
        ex.setOperator(stranger, true);
        vm.expectRevert(X.NotAdmin.selector);
        ex.setResolver(stranger);
        vm.expectRevert(X.NotAdmin.selector);
        ex.transferAdmin(stranger);
        vm.expectRevert(X.NotAdmin.selector);
        ex.createMarket(2, 0, uint64(block.timestamp + 1 days), uint64(block.timestamp + 2 days), 1e9, bytes32(0));
        vm.expectRevert(X.NotAdminOrResolver.selector);
        ex.closeEarly(m);
        vm.expectRevert(X.NotAdminOrResolver.selector);
        ex.proposeOutcome(m, 0, bytes32(0));
        vm.expectRevert(X.NotTreasury.selector);
        ex.withdrawTreasury();
        vm.stopPrank();
    }

    function test_transferAdmin_twoStep() public {
        vm.expectEmit(true, false, false, true, address(ex));
        emit X.AdminTransferStarted(stranger);
        ex.transferAdmin(stranger);
        assertEq(ex.admin(), address(this), "nothing changes until the new admin accepts");
        vm.prank(operator);
        vm.expectRevert(X.NotAdmin.selector);
        ex.acceptAdmin();
        vm.prank(stranger);
        ex.acceptAdmin();
        assertEq(ex.admin(), stranger);
        assertEq(ex.pendingAdmin(), address(0));
        // the old admin has lost its power
        vm.expectRevert(X.NotAdmin.selector);
        ex.setPaused(true);
        // and a second accept does nothing
        vm.prank(stranger);
        vm.expectRevert(X.NotAdmin.selector);
        ex.acceptAdmin();
        // nobody can accept when none is pending
        vm.prank(address(0));
        vm.expectRevert(X.NotAdmin.selector);
        ex.acceptAdmin();
    }

    function test_setResolver_adminOnly() public {
        vm.prank(stranger);
        vm.expectRevert(X.NotAdmin.selector);
        ex.setResolver(stranger);
        ex.setResolver(stranger);
        assertEq(ex.resolver(), stranger);
        // the resolver may propose but not administer
        vm.prank(stranger);
        vm.expectRevert(X.NotAdmin.selector);
        ex.setPaused(true);
    }

    // ------------------------------------------------------------------------------------------------ O5: the counterparty rule
    function _asParty(address who, bool takerSide) internal view returns (Call memory c) {
        c = _dBuy1(10e6);
        if (takerSide) c.t = _order(who, m, 0, true, 70, 10e6);
        else c.ms[0] = _order(who, m, 0, false, 40, 10e6);
        _resign(c);
    }

    function test_O5_operatorAdminResolverTreasury_areRefused_asTakerAndAsMaker() public {
        (, address op) = _party("opKey", m, 1_000e6, 100e6);
        (, address adm) = _party("admKey", m, 1_000e6, 100e6);
        (, address res) = _party("resKey", m, 1_000e6, 100e6);
        ex.setOperator(op, true);
        ex.setResolver(res);
        ex.transferAdmin(adm);
        vm.prank(adm);
        ex.acceptAdmin();
        address[3] memory holders = [op, adm, res];
        for (uint256 i; i < 3; ++i) {
            Call memory c = _asParty(holders[i], true);
            _expectNoWrite(abi.encodeWithSelector(X.PartyRefused.selector, _hash(c.t)), _data(c));
            c = _asParty(holders[i], false);
            _expectNoWrite(abi.encodeWithSelector(X.PartyRefused.selector, _hash(c.ms[0])), _data(c));
        }
        // TREASURY is an immutable: a fresh exchange whose treasury is a wallet with a key
        (, address tr) = _party("trKey", m, 0, 0);
        MockUSDC usd2 = usd;
        X ex2 = new X(address(usd2), tr);
        assertEq(ex2.TREASURY(), tr);
        // run the same call on ex2: market, funds and a signed order from the treasury
        ex2.setOperator(operator, true);
        uint256 m2 = ex2.createMarket(
            3, FEE, uint64(block.timestamp + 30 days), uint64(block.timestamp + 31 days), CAP, bytes32(0)
        );
        usd2.mint(T, 100e6);
        vm.startPrank(T);
        usd2.approve(address(ex2), type(uint256).max);
        ex2.deposit(100e6);
        vm.stopPrank();
        usd2.mint(tr, 100e6);
        vm.startPrank(tr);
        usd2.approve(address(ex2), type(uint256).max);
        ex2.deposit(100e6);
        ex2.mintSets(m2, 50e6);
        vm.stopPrank();
        X.Order memory to = X.Order(1, T, m2, 0, true, 70, 10e6, uint64(block.timestamp + 1 days), 0);
        X.Order memory mo = X.Order(2, tr, m2, 0, false, 40, 10e6, uint64(block.timestamp + 1 days), 0);
        bytes32 th = _hashOn(ex2, to);
        bytes32 mh = _hashOn(ex2, mo);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(keyOf[T], th);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(keyOf[tr], mh);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(X.PartyRefused.selector, mh));
        ex2.matchOrders(
            to, abi.encodePacked(r1, s1, v1), _one(mo), _oneSig(abi.encodePacked(r2, s2, v2)), _oneFill(10e6), 10e6
        );
    }

    function _hashOn(X e, X.Order memory o) internal view returns (bytes32) {
        bytes32 sep = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("Mako Market Exchange"), keccak256("1"), vm.getChainId(), address(e))
        );
        bytes32 sh = keccak256(
            abi.encode(
                ORDER_TYPEHASH, o.salt, o.maker, o.marketId, o.option, o.isBuy, o.price, o.size, o.expiration, o.nonce
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", sep, sh));
    }

    function test_O5_theRolesAreReadAtTheTimeOfTheCall() public {
        (, address op) = _party("opKey", m, 1_000e6, 100e6);
        // not an operator yet: an order of this wallet settles
        Call memory c = _asParty(op, false);
        uint256 snap = vm.snapshotState();
        _send(c);
        vm.revertToState(snap);
        // while it is an operator: refused
        ex.setOperator(op, true);
        _expectNoWrite(abi.encodeWithSelector(X.PartyRefused.selector, _hash(c.ms[0])), _data(c));
        // after removal: NOT refused again (policy, not code, covers the rest: plan section 3.4)
        ex.setOperator(op, false);
        _send(c);
    }

    function test_O5_residual_aFreshUnlistedWallet_isNotRefused_andSettlesAgainstAUser() public {
        (, address fresh) = _party("fresh", m, 1_000e6, 100e6);
        Call memory c = _asParty(fresh, false);
        _send(c);
        assertEq(ex.positionOf(m, 0, fresh), 90e6);
    }

    function test_O5_residual_aFormerResolverAndAFormerAdminAreNotRefused() public {
        // the rewards key of the plan is any wallet that holds none of the four roles; a wallet that once held one is such
        (, address x) = _party("formerHolder", m, 1_000e6, 100e6);
        ex.setResolver(x);
        Call memory c = _asParty(x, false);
        _expectNoWrite(abi.encodeWithSelector(X.PartyRefused.selector, _hash(c.ms[0])), _data(c));
        ex.setResolver(makeAddr("anotherResolver"));
        uint256 snap = vm.snapshotState();
        _send(c); // no longer the resolver: not refused
        vm.revertToState(snap);
        // the same for the admin role, passed on and back off
        ex.transferAdmin(x);
        vm.prank(x);
        ex.acceptAdmin();
        _expectNoWrite(abi.encodeWithSelector(X.PartyRefused.selector, _hash(c.ms[0])), _data(c));
        vm.prank(x);
        ex.transferAdmin(address(this));
        ex.acceptAdmin();
        _send(c);
    }

    // ------------------------------------------------------------------------------------------------ pause
    function test_pause_stopsMatchingMintingAndNewMarkets_butNotTheRest_X10() public {
        Call memory c = _dBuy1(10e6);
        ex.setPaused(true);
        _expectNoWrite(_e(X.Paused.selector), _data(c));
        vm.prank(T);
        vm.expectRevert(X.Paused.selector);
        ex.mintSets(m, LOT);
        vm.expectRevert(X.Paused.selector);
        ex.createMarket(2, 0, uint64(block.timestamp + 1 days), uint64(block.timestamp + 2 days), 1e9, bytes32(0));
        // these keep working: withdraw, merge, cancel, nonce, redeem, finalize
        vm.startPrank(T);
        ex.mergeSets(m, 10e6);
        ex.withdraw(1e6);
        ex.cancelOrders(_one(c.t));
        ex.incrementNonce();
        vm.stopPrank();
        ex.setPaused(false);
        _send(_dBuy1(10e6)); // T's nonce moved: the order built now carries the new one
    }

    function test_pause_adminOnly_andEvent() public {
        vm.prank(stranger);
        vm.expectRevert(X.NotAdmin.selector);
        ex.setPaused(true);
        vm.expectEmit(false, false, false, true, address(ex));
        emit X.PausedSet(true);
        ex.setPaused(true);
        assertTrue(ex.paused());
    }

    function test_pause_doesNotBlockResolutionOrRedeem_X10() public {
        ex.setPaused(true);
        vm.warp(block.timestamp + 31 days);
        ex.proposeOutcome(m, 0, bytes32(0));
        vm.warp(block.timestamp + 24 hours);
        ex.finalize(m);
        vm.prank(T);
        ex.redeem(m);
        assertEq(ex.cash(T), 10_000e6 + 2_000e6, "T's 2,000 option-0 shares pay 1 USDC each");
    }

    // ------------------------------------------------------------------------------------------------ closeEarly
    function test_closeEarly_adminOrResolver_forwardOnly() public {
        uint64 close = ex.marketOf(m).tradingClose;
        vm.prank(stranger);
        vm.expectRevert(X.NotAdminOrResolver.selector);
        ex.closeEarly(m);
        vm.warp(block.timestamp + 5 days);
        ex.closeEarly(m);
        assertEq(ex.marketOf(m).tradingClose, uint64(block.timestamp));
        assertLt(ex.marketOf(m).tradingClose, close);
        // never later: after the close time has passed it changes nothing
        vm.warp(block.timestamp + 40 days);
        uint64 was = ex.marketOf(m).tradingClose;
        ex.closeEarly(m);
        assertEq(ex.marketOf(m).tradingClose, was);
        // a resolver other than the admin may do it too
        uint256 m2 = _market(2);
        address res = makeAddr("res2");
        ex.setResolver(res);
        vm.prank(res);
        ex.closeEarly(m2);
        // an unknown or finalized market
        vm.expectRevert(X.BadMarket.selector);
        ex.closeEarly(999);
    }

    // ------------------------------------------------------------------------------------------------ cash
    function test_deposit_withdraw_roundTrip() public {
        (, address a) = _party("dw", m, 0, 0);
        usd.mint(a, 5e6);
        vm.prank(a);
        usd.approve(address(ex), 5e6);
        vm.expectEmit(true, false, false, true, address(ex));
        emit X.Deposited(a, 5e6);
        vm.prank(a);
        ex.deposit(5e6);
        assertEq(ex.cash(a), 5e6);
        vm.expectEmit(true, false, false, true, address(ex));
        emit X.Withdrawn(a, 2e6);
        vm.prank(a);
        ex.withdraw(2e6);
        assertEq(ex.cash(a), 3e6);
        assertEq(usd.balanceOf(a), 2e6);
        vm.prank(a);
        ex.withdraw(3e6);
        assertEq(ex.cash(a), 0, "the sentinel never leaks into the reported amount");
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(X.InsufficientCash.selector, bytes32(0)));
        ex.withdraw(1);
    }

    function test_withdraw_neverPausable_X10() public {
        ex.setPaused(true);
        vm.prank(T);
        ex.withdraw(1e6);
    }

    function _freshWith(MockUSDC token) internal returns (X e) {
        e = new X(address(token), treasury);
    }

    function test_deposit_onlyExactUSDC_isCredited() public {
        address a = makeAddr("tokUser");
        FeeOnTransferUSDC fee = new FeeOnTransferUSDC();
        X e = _freshWith(fee);
        fee.mint(a, 100e6);
        vm.startPrank(a);
        fee.approve(address(e), 100e6);
        vm.expectRevert(abi.encodeWithSelector(X.InexactTransfer.selector, 100e6, 99e6));
        e.deposit(100e6);
        vm.stopPrank();
        OvershootUSDC over = new OvershootUSDC();
        e = _freshWith(over);
        over.mint(a, 100e6);
        vm.startPrank(a);
        over.approve(address(e), 100e6);
        vm.expectRevert(abi.encodeWithSelector(X.InexactTransfer.selector, 100e6, 100e6 + 1));
        e.deposit(100e6);
        vm.stopPrank();
        FalseReturnUSDC fr = new FalseReturnUSDC();
        e = _freshWith(fr);
        vm.prank(a);
        vm.expectRevert(X.TransferFailed.selector);
        e.deposit(1);
        RevertingUSDC rv = new RevertingUSDC();
        e = _freshWith(rv);
        vm.prank(a);
        vm.expectRevert(X.TransferFailed.selector);
        e.deposit(1);
        MalformedReturnUSDC mal = new MalformedReturnUSDC();
        e = _freshWith(mal);
        mal.mint(a, 1e6);
        vm.startPrank(a);
        mal.approve(address(e), 1e6);
        vm.expectRevert(X.TransferFailed.selector);
        e.deposit(1e6);
        vm.stopPrank();
        // a token that returns nothing is accepted: the balance check carries it
        NoReturnUSDC nr = new NoReturnUSDC();
        e = _freshWith(nr);
        nr.mint(a, 1e6);
        vm.startPrank(a);
        nr.approve(address(e), 1e6);
        e.deposit(1e6);
        vm.stopPrank();
        assertEq(e.cash(a), 1e6);
    }

    function test_withdraw_shortTransferReverts() public {
        ShortTransferUSDC st = new ShortTransferUSDC();
        X e = _freshWith(st);
        address a = makeAddr("shortUser");
        st.mint(a, 10e6);
        vm.startPrank(a);
        st.approve(address(e), 10e6);
        e.deposit(10e6);
        vm.stopPrank();
        st.setShortchange(true);
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(X.InexactTransfer.selector, 10e6, 10e6 - 1));
        e.withdraw(10e6);
        assertEq(e.cash(a), 10e6, "the revert undoes the debit");
    }

    function test_reentrancy_depositWithdrawAndTreasury_areGuarded() public {
        ReentrantUSDC rt = new ReentrantUSDC();
        X e = _freshWith(rt);
        address a = makeAddr("reUser");
        rt.mint(a, 10e6);
        vm.startPrank(a);
        rt.approve(address(e), type(uint256).max);
        vm.stopPrank();
        // re-enter deposit from inside deposit's transferFrom
        rt.arm(address(e), abi.encodeCall(X.deposit, (1)));
        vm.prank(a);
        e.deposit(5e6);
        assertEq(bytes4(rt.lastRevert()), X.Reentrancy.selector, "deposit re-entering deposit");
        assertEq(e.cash(a), 5e6, "credited once");
        // re-enter withdraw from inside withdraw's transfer
        rt.arm(address(e), abi.encodeCall(X.withdraw, (1)));
        vm.prank(a);
        e.withdraw(1e6);
        assertEq(bytes4(rt.lastRevert()), X.Reentrancy.selector, "withdraw re-entering withdraw");
        assertEq(e.cash(a), 4e6, "paid once");
    }

    // ------------------------------------------------------------------------------------------------ mintSets and mergeSets
    function test_mintSets_errors() public {
        (, address a) = _party("ms", m, 100e6, 0);
        vm.startPrank(a);
        vm.expectRevert(X.BadMarket.selector);
        ex.mintSets(999, LOT);
        vm.expectRevert(X.BadSize.selector);
        ex.mintSets(m, 0);
        vm.expectRevert(X.BadSize.selector);
        ex.mintSets(m, LOT + 1);
        vm.expectRevert(abi.encodeWithSelector(X.InsufficientCash.selector, bytes32(0)));
        ex.mintSets(m, 1_000e6);
        vm.stopPrank();
        ex.setPaused(true);
        vm.prank(a);
        vm.expectRevert(X.Paused.selector);
        ex.mintSets(m, LOT);
        ex.setPaused(false);
        ex.closeEarly(m);
        vm.prank(a);
        vm.expectRevert(X.TradingClosed.selector);
        ex.mintSets(m, LOT);
    }

    function test_mintSets_positionCap() public {
        uint256 mc = _marketCap(2, FEE, 10e6);
        (, address a) = _party("cap", mc, 100e6, 10e6);
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(X.PositionCap.selector, bytes32(0)));
        ex.mintSets(mc, LOT);
    }

    function test_mergeSets_errors() public {
        (, address a) = _party("mg", m, 0, 10e6);
        vm.startPrank(a);
        vm.expectRevert(X.BadMarket.selector);
        ex.mergeSets(999, LOT);
        vm.expectRevert(X.BadSize.selector);
        ex.mergeSets(m, 0);
        vm.expectRevert(X.BadSize.selector);
        ex.mergeSets(m, LOT + 1);
        vm.expectRevert(abi.encodeWithSelector(X.InsufficientShares.selector, bytes32(0)));
        ex.mergeSets(m, 11e6);
        vm.stopPrank();
    }

    function test_mergeSets_oneShortOptionBlocksIt() public {
        // A holds 10 of every option, sells 5 of option 1: it can merge 5 sets at most
        _settle1(keyOf[B], _order(B, m, 1, true, 50, 5e6), keyOf[A], _order(A, m, 1, false, 40, 5e6), 5e6);
        vm.prank(A);
        vm.expectRevert(abi.encodeWithSelector(X.InsufficientShares.selector, bytes32(0)));
        ex.mergeSets(m, 2_000e6);
    }

    // ------------------------------------------------------------------------------------------------ resolution
    function _close() internal {
        vm.warp(ex.marketOf(m).tradingClose);
    }

    function test_proposeOutcome_errors() public {
        vm.prank(stranger);
        vm.expectRevert(X.NotAdminOrResolver.selector);
        ex.proposeOutcome(m, 0, bytes32(0));
        vm.expectRevert(X.TradingOpen.selector);
        ex.proposeOutcome(m, 0, bytes32(0));
        _close();
        vm.expectRevert(X.BadOption.selector);
        ex.proposeOutcome(m, 3, bytes32(0));
        vm.expectRevert(X.BadMarket.selector);
        ex.proposeOutcome(999, 0, bytes32(0));
        // too late: the veto would end after resolutionDeadline + 7 days
        uint256 b = uint256(ex.marketOf(m).resolutionDeadline) + 7 days;
        vm.warp(b - 24 hours + 1);
        vm.expectRevert(X.ProposalTooLate.selector);
        ex.proposeOutcome(m, 0, bytes32(0));
        vm.warp(b - 24 hours);
        ex.proposeOutcome(m, 0, bytes32(0)); // exactly on the line is allowed
    }

    function test_proposal_canBeCorrectedInTheVeto_notAfter() public {
        _close();
        ex.proposeOutcome(m, 0, bytes32(uint256(1)));
        vm.warp(block.timestamp + 23 hours);
        ex.proposeOutcome(m, 1, bytes32(uint256(2))); // a correction inside the veto restarts it
        assertEq(ex.marketOf(m).proposedOutcome, 1);
        assertEq(ex.marketOf(m).evidenceHash, bytes32(uint256(2)));
        uint64 fa = ex.marketOf(m).finalizableAt;
        vm.warp(fa);
        vm.expectRevert(X.VetoElapsed.selector); // after the veto it can no longer be replaced
        ex.proposeOutcome(m, 2, bytes32(0));
        ex.finalize(m);
        assertEq(ex.marketOf(m).finalOutcome, 1);
    }

    function test_finalize_errors_andEffects_X8_X17() public {
        vm.expectRevert(X.NoProposal.selector);
        ex.finalize(m);
        _close();
        vm.expectRevert(X.NoProposal.selector);
        ex.finalize(m);
        ex.proposeOutcome(m, 2, bytes32(0));
        vm.expectRevert(X.VetoRunning.selector);
        ex.finalize(m);
        // a trade first so there are fees to release
        vm.warp(block.timestamp - 31 days + 1 days);
        vm.warp(ex.marketOf(m).finalizableAt);
        uint256 treasuryBefore = ex.treasuryBalance();
        ex.finalize(m);
        X.Market memory mk = ex.marketOf(m);
        assertEq(mk.status, 2);
        assertEq(mk.finalOutcome, 2);
        assertEq(mk.feesHeld, 0);
        assertEq(ex.treasuryBalance(), treasuryBefore);
        vm.expectRevert(X.BadMarket.selector);
        ex.finalize(m); // once
        vm.expectRevert(X.BadMarket.selector);
        ex.proposeOutcome(m, 1, bytes32(0)); // a finalized outcome never changes
        vm.expectRevert(X.BadMarket.selector);
        ex.closeEarly(m);
    }

    function test_finalize_winner_releasesFeesToTheTreasuryOnce_andPaysWinners() public {
        _send(_dBuy1(100e6));
        uint256 fees = ex.marketOf(m).feesHeld;
        assertGt(fees, 0);
        _close();
        ex.proposeOutcome(m, 0, bytes32(0));
        vm.warp(block.timestamp + 24 hours);
        ex.finalize(m);
        assertEq(ex.treasuryBalance(), fees);
        vm.prank(T);
        ex.redeem(m);
        assertEq(ex.cash(T), 10_000e6 - 41_680_000 + 2_100e6, "2,100 winning shares at 1 USDC each");
        vm.prank(treasury);
        ex.withdrawTreasury();
        assertEq(usd.balanceOf(treasury), fees);
        assertEq(ex.treasuryBalance(), 0);
    }

    function test_unwind_paysEachWalletItsNet_X16() public {
        _send(_dBuy1(100e6));
        uint256 tNet = _net(m, T);
        uint256 aNet = _net(m, A);
        uint256 tCash = ex.cash(T);
        uint256 aCash = ex.cash(A);
        _close();
        ex.proposeOutcome(m, 255, bytes32(0));
        vm.warp(block.timestamp + 24 hours);
        ex.finalize(m);
        X.Market memory mk = ex.marketOf(m);
        assertEq(mk.status, 3);
        assertEq(mk.collateral + mk.feesHeld + mk.profitHeldTotal, 0, "moved into the pool");
        vm.prank(T);
        ex.redeem(m);
        vm.prank(A);
        ex.redeem(m);
        vm.prank(T);
        ex.redeem(m); // once: the second pays nothing
        assertEq(ex.cash(T), tCash + tNet);
        assertEq(ex.cash(A), aCash + aNet);
        vm.prank(B);
        ex.redeem(m);
        vm.prank(C);
        ex.redeem(m);
        assertEq(ex.marketOf(m).unwindPool, 0, "the pool ends at zero: every trader was paid exactly its net");
    }

    function test_backstopUnwind_X11_X19() public {
        _close();
        uint256 b = uint256(ex.marketOf(m).resolutionDeadline) + 7 days;
        vm.prank(stranger);
        vm.expectRevert(X.BackstopNotOpen.selector);
        ex.backstopUnwind(m);
        vm.warp(b - 1);
        vm.expectRevert(X.BackstopNotOpen.selector);
        ex.backstopUnwind(m);
        vm.warp(b);
        // a proposal exists: the backstop is closed
        uint256 snap = vm.snapshotState();
        vm.warp(b - 24 hours);
        ex.proposeOutcome(m, 0, bytes32(0));
        vm.warp(b);
        vm.prank(stranger);
        vm.expectRevert(X.ProposalPending.selector);
        ex.backstopUnwind(m);
        ex.finalize(m); // and finalize is open: exactly one of the two is valid
        vm.revertToState(snap);
        // no proposal: anyone may unwind, and finalize has nothing to finalize
        vm.expectRevert(X.NoProposal.selector);
        ex.finalize(m);
        vm.prank(stranger);
        ex.backstopUnwind(m);
        assertEq(ex.marketOf(m).status, 3);
        assertEq(ex.marketOf(m).finalOutcome, 255);
        vm.expectRevert(X.BadMarket.selector);
        ex.backstopUnwind(m);
    }

    function test_redeem_beforeSettlement_isNotSettled() public {
        vm.expectRevert(X.NotSettled.selector);
        ex.redeem(m);
    }

    function test_withdrawTreasury_errors() public {
        vm.prank(stranger);
        vm.expectRevert(X.NotTreasury.selector);
        ex.withdrawTreasury();
        vm.prank(treasury);
        vm.expectRevert(X.NothingOwed.selector);
        ex.withdrawTreasury();
    }

    // ------------------------------------------------------------------------------------------------ views
    function test_feeOf_andSplitOf_agreeWithTheChargedFee_X5_X20() public {
        assertEq(ex.feeOf(m, 100e6, 40), 1_680_000);
        assertEq(ex.feeOf(m, 100e6, 0), 0);
        assertEq(ex.feeOf(m, 100e6, 99), _fee(100e6, 99));
        _send(_dBuy1(100e6));
        assertEq(ex.marketOf(m).feesHeld, ex.feeOf(m, 100e6, 40));
        uint256 zero = _marketCap(2, 0, CAP);
        assertEq(ex.feeOf(zero, 100e6, 40), 0, "zero fee rate");
        vm.expectRevert(abi.encodeWithSelector(X.BadOrderField.selector, bytes32(0)));
        ex.feeOf(m, 100e6, 100);
        vm.expectRevert(abi.encodeWithSelector(X.BadOrderField.selector, bytes32(0)));
        ex.feeOf(m, uint256(type(uint128).max) + 1, 40);
        (uint256 f, uint256 h) = ex.splitOf(m, T, 5e6);
        assertEq(f, 5e6);
        assertEq(h, 0);
        (f, h) = ex.splitOf(m, address(0xBEEF), 5e6);
        assertEq(f, 0, "a wallet with no net holds the whole receipt");
        assertEq(h, 5e6);
    }

    function test_feeRoundsUp_neverDown() public view {
        // one lot at price 1: 700 x 10,000 x 1 x 99 / 1e8 = 6.93, rounded up to 7
        assertEq(ex.feeOf(m, LOT, 1), 7);
        assertEq(_fee(LOT, 1), 7);
        // a rate of zero is zero
    }
}
