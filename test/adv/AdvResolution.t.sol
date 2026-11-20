// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {ExchangeBase} from "../exchange/ExchangeBase.sol";
import {MakoOutcomeExchangeV1 as X} from "../../src/MakoOutcomeExchangeV1.sol";

/// Adversary: resolution timing edges and role checks (spec MAKO_POOLS_PLAN 7.1, X11, X19; OFFCHAIN 3.3).
contract AdvResolution is ExchangeBase {
    uint256 internal m;
    uint64 internal tc;
    uint64 internal rd;
    address internal resolverA = makeAddr("resolverA");

    function setUp() public override {
        super.setUp();
        vm.warp(1_700_000_000);
        tc = uint64(block.timestamp + 10 days);
        rd = uint64(block.timestamp + 12 days);
        m = ex.createMarket(3, 700, tc, rd, CAP, bytes32(0));
        ex.setResolver(resolverA);
    }

    function _propose(uint8 o) internal {
        vm.prank(resolverA);
        ex.proposeOutcome(m, o, bytes32(uint256(1)));
    }

    function test_veto_boundaries_proposeVsFinalize_neverBothValidAtOneSecond() public {
        vm.warp(tc);
        _propose(1);
        uint64 fa = ex.marketOf(m).finalizableAt;
        assertEq(fa, tc + 1 days);
        vm.warp(fa - 1);
        vm.expectRevert(X.VetoRunning.selector);
        ex.finalize(m);
        vm.warp(fa);
        // at exactly finalizableAt finalize is valid, so a re-proposal must not also be valid
        vm.prank(resolverA);
        vm.expectRevert(X.VetoElapsed.selector);
        ex.proposeOutcome(m, 2, bytes32(0));
        ex.finalize(m);
    }

    function test_proposalDeadline_exactBoundary_andBackstopRace() public {
        uint256 b = uint256(rd) + 7 days;
        vm.warp(b - 1 days);
        _propose(0); // now + 24h == B: allowed
        vm.warp(b - 1 days + 1);
        // a correction now would end past B
        vm.prank(resolverA);
        vm.expectRevert(X.ProposalTooLate.selector);
        ex.proposeOutcome(m, 1, bytes32(0));
        vm.warp(b - 1);
        vm.expectRevert(X.BackstopNotOpen.selector);
        ex.backstopUnwind(m);
        vm.warp(b);
        vm.expectRevert(X.ProposalPending.selector);
        ex.backstopUnwind(m);
        ex.finalize(m);
        assertEq(ex.marketOf(m).finalOutcome, 0);
    }

    function test_backstop_noProposal_atExactlyB() public {
        uint256 b = uint256(rd) + 7 days;
        vm.warp(b - 1);
        vm.expectRevert(X.BackstopNotOpen.selector);
        ex.backstopUnwind(m);
        vm.warp(b);
        ex.backstopUnwind(m);
        assertEq(ex.marketOf(m).status, 3);
        // a proposal after the backstop can never revive the market
        vm.prank(resolverA);
        vm.expectRevert(X.BadMarket.selector);
        ex.proposeOutcome(m, 0, bytes32(0));
    }

    function test_proposeBeforeClose_reverts_atExactClose_ok() public {
        vm.warp(tc - 1);
        vm.prank(resolverA);
        vm.expectRevert(X.TradingOpen.selector);
        ex.proposeOutcome(m, 0, bytes32(0));
        vm.warp(tc);
        _propose(0);
    }

    function test_correctionCanSwitchToUnwindAndBack_andFinalizeHonoursTheLast() public {
        vm.warp(tc + 1);
        _propose(0);
        vm.warp(tc + 2 hours);
        _propose(255);
        vm.warp(tc + 3 hours);
        _propose(2);
        vm.warp(tc + 3 hours + 1 days);
        ex.finalize(m);
        X.Market memory k = ex.marketOf(m);
        assertEq(k.status, 2);
        assertEq(k.finalOutcome, 2);
    }

    function test_roleChecks_proposeFinalizeClose() public {
        address stranger = makeAddr("stranger");
        vm.warp(tc);
        vm.prank(stranger);
        vm.expectRevert(X.NotAdminOrResolver.selector);
        ex.proposeOutcome(m, 0, bytes32(0));
        vm.prank(operator);
        vm.expectRevert(X.NotAdminOrResolver.selector);
        ex.proposeOutcome(m, 0, bytes32(0));
        vm.prank(operator);
        vm.expectRevert(X.NotAdminOrResolver.selector);
        ex.closeEarly(m);
        vm.prank(stranger);
        vm.expectRevert(X.NotAdminOrResolver.selector);
        ex.closeEarly(m);
        // outcome bounds
        vm.prank(resolverA);
        vm.expectRevert(X.BadOption.selector);
        ex.proposeOutcome(m, 3, bytes32(0));
        vm.prank(resolverA);
        vm.expectRevert(X.BadOption.selector);
        ex.proposeOutcome(m, 254, bytes32(0));
    }

    function test_unknownMarket_everywhere_isNamedNeverPanic() public {
        vm.expectRevert(X.BadMarket.selector);
        ex.finalize(999);
        vm.expectRevert(X.BadMarket.selector);
        ex.backstopUnwind(999);
        vm.expectRevert(X.NotSettled.selector);
        ex.redeem(999);
        vm.expectRevert(X.BadMarket.selector);
        ex.mintSets(999, LOT);
        vm.expectRevert(X.BadMarket.selector);
        ex.mergeSets(999, LOT);
        vm.expectRevert(X.BadMarket.selector);
        ex.closeEarly(999);
        vm.prank(resolverA);
        vm.expectRevert(X.BadMarket.selector);
        ex.proposeOutcome(999, 0, bytes32(0));
        vm.expectRevert(X.BadMarket.selector);
        ex.finalize(0);
    }
}
