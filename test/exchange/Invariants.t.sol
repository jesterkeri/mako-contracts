// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ExchangeHandler} from "./ExchangeHandler.sol";
import {MakoOutcomeExchangeV1 as X} from "../../src/MakoOutcomeExchangeV1.sol";
import {MockUSDC} from "../mocks/TokenMocks.sol";

/// @notice Foundry invariant suite for MakoOutcomeExchangeV1: X1 to X12 and X15 to X20 of MAKO_POOLS_PLAN section 9.3
/// reworded as plan section 10.2 says (no escrow, no book), and O1, O3, O4, O8. See `ExchangeHandler` for the actions.
///
/// IMPLEMENTED: X1, X2, X3, X4, X5, X6, X7, X8, X9, X10, X11, X12, X15, X16, X17, X18, X19, X20 and O1, O3, O4, O8.
/// NOT here, covered by named unit tests instead: X13, X14 and X21 (book-only, removed with the book); O2, O5, O6, O7,
/// O9 to O13 (signature and match rules: `Signatures.t.sol`, `StepOrder.t.sol`, `Admin.t.sol`, `Fuzz.t.sol`).
contract InvariantsTest is StdInvariant, Test {
    ExchangeHandler internal h;
    X internal ex;
    MockUSDC internal usd;

    function setUp() public {
        h = new ExchangeHandler();
        ex = h.exchange();
        usd = h.token();
        targetContract(address(h));
        // the trading actions appear three times so most calls trade; the admin and resolution ones once
        bytes4[] memory sels = new bytes4[](28);
        for (uint256 i; i < 3; ++i) {
            sels[i * 5 + 0] = h.act_deposit.selector;
            sels[i * 5 + 1] = h.act_mint.selector;
            sels[i * 5 + 2] = h.act_direct.selector;
            sels[i * 5 + 3] = h.act_set.selector;
            sels[i * 5 + 4] = h.act_merge.selector;
        }
        sels[15] = h.act_withdraw.selector;
        sels[16] = h.act_cancel.selector;
        sels[17] = h.act_nonce.selector;
        sels[18] = h.act_notOperator.selector;
        sels[19] = h.act_warp.selector;
        sels[20] = h.act_pause.selector;
        sels[21] = h.act_closeEarly.selector;
        sels[22] = h.act_propose.selector;
        sels[23] = h.act_finalize.selector;
        sels[24] = h.act_backstop.selector;
        sels[25] = h.act_redeem.selector;
        sels[26] = h.act_withdrawTreasury.selector;
        sels[27] = h.act_cancel.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sels}));
    }

    function _wallets() internal view returns (address[4] memory w) {
        for (uint256 i; i < 4; ++i) {
            w[i] = h.party(i);
        }
    }

    // ------------------------------------------------------------------------------------------------ conservation
    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 80
    /// forge-config: ci.invariant.runs = 96
    /// forge-config: ci.invariant.depth = 80
    function invariant_X1_X2_X15_conservation() public view {
        address[4] memory w = _wallets();
        uint256 owed;
        uint256 cashSum;
        for (uint256 i; i < 4; ++i) {
            cashSum += ex.cash(w[i]);
        }
        for (uint256 mi; mi < 2; ++mi) {
            uint256 m = h.mk(mi);
            X.Market memory k = ex.marketOf(m);
            uint256 sumNet;
            uint256 sumHeld;
            for (uint256 i; i < 4; ++i) {
                (uint256 n, uint256 hl) = ex.recOf(m, w[i]);
                sumNet += n;
                sumHeld += hl;
            }
            if (k.status == 1) {
                // X1: before finalization every option's shares equal the sets outstanding (no escrow in this design)
                for (uint8 o; o < k.nOptions; ++o) {
                    uint256 s;
                    for (uint256 i; i < 4; ++i) {
                        s += ex.positionOf(m, o, w[i]);
                    }
                    assertEq(s, k.setsOutstanding, "X1");
                }
                // X15: collateral + feesHeld + sum of profitHeld == sum of nets (every net >= 0 by type)
                assertEq(uint256(k.collateral) + k.feesHeld + sumHeld, sumNet, "X15");
                assertEq(k.collateral, k.setsOutstanding, "one USDC backs each set");
            }
            assertEq(sumHeld, k.profitHeldTotal + (k.status == 3 ? sumHeld : 0), "held profit is accounted"); // after an unwind each wallet's held is cleared on redeem
            owed += uint256(k.collateral) + k.feesHeld + k.profitHeldTotal + k.unwindPool;
        }
        // X2 (as an equality: no transfer reaches the exchange except through deposit and settlement)
        assertEq(usd.balanceOf(address(ex)), cashSum + owed + ex.treasuryBalance(), "X2");
    }

    // ------------------------------------------------------------------------------------------------ the ghost flags
    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 80
    /// forge-config: ci.invariant.runs = 96
    /// forge-config: ci.invariant.depth = 80
    function invariant_X3_X4_X5_X9_X18_X20_everySuccessfulActionDidExactlyItsWork() public view {
        assertFalse(h.gMoney(), "money flow, fee, split or an uninvolved wallet");
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 80
    /// forge-config: ci.invariant.runs = 96
    /// forge-config: ci.invariant.depth = 80
    function invariant_X6_noFillOrMintAfterCloseWhilePausedOrAfterFinalization() public view {
        assertFalse(h.gClosed(), "X6 / X12");
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 80
    /// forge-config: ci.invariant.runs = 96
    /// forge-config: ci.invariant.depth = 80
    function invariant_X7_X10_pauseProofActionsAndCancelAreSound() public view {
        assertFalse(h.gPauseProof(), "X10");
        assertFalse(h.gCancelOnly(), "X7");
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 80
    /// forge-config: ci.invariant.runs = 96
    /// forge-config: ci.invariant.depth = 80
    function invariant_X8_statusOnlyMovesForward_aFinalOutcomeNeverChanges() public view {
        assertFalse(h.gStatus(), "X8");
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 80
    /// forge-config: ci.invariant.runs = 96
    /// forge-config: ci.invariant.depth = 80
    function invariant_X11_X19_backstopAndFinalizeAreNeverBothValid() public view {
        assertFalse(h.gBackstop(), "X11 / X19");
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 80
    /// forge-config: ci.invariant.runs = 96
    /// forge-config: ci.invariant.depth = 80
    function invariant_X16_X17_unwindAndReleasePayExactlyOnce() public view {
        assertFalse(h.gUnwind(), "X16");
        assertFalse(h.gRelease(), "X17");
        for (uint256 mi; mi < 2; ++mi) {
            X.Market memory k = ex.marketOf(h.mk(mi));
            // once every wallet has redeemed after an unwind, the pool is exactly empty
            if (k.status == 3 && h.unwindAllRedeemed(mi)) assertEq(k.unwindPool, 0, "X16 pool ends at zero");
        }
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 80
    /// forge-config: ci.invariant.runs = 96
    /// forge-config: ci.invariant.depth = 80
    function invariant_X12_marketTermsNeverChange_tradingCloseOnlyMovesEarlier() public view {
        for (uint256 mi; mi < 2; ++mi) {
            X.Market memory k = ex.marketOf(h.mk(mi));
            assertEq(k.nOptions, mi == 0 ? 3 : 2);
            assertEq(k.feeRate, mi == 0 ? 700 : 100);
            assertEq(k.positionCap, 1_000_000 * 1_000_000);
            assertLe(k.tradingClose, h.initialClose(mi));
            assertEq(k.resolutionDeadline, h.initialClose(mi) + 1 days);
        }
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 80
    /// forge-config: ci.invariant.runs = 96
    /// forge-config: ci.invariant.depth = 80
    function invariant_O1_O3_O4_filledOnlyGrows_neverPastSize_noSpentOrOldOrganisedOrder_onlyOperatorsSettle()
        public
        view
    {
        assertFalse(h.checkFilled(), "O1 filled shrank or passed the size");
        assertFalse(h.gNonceCancel(), "O3 a cancelled, stale or over-filled order filled");
        assertFalse(h.gOperatorOnly(), "O4");
    }

    /// forge-config: default.invariant.runs = 96
    /// forge-config: default.invariant.depth = 80
    /// forge-config: ci.invariant.runs = 96
    /// forge-config: ci.invariant.depth = 80
    function invariant_O8_noOperatorHoldsASecondRole() public view {
        address[4] memory w = _wallets();
        address[6] memory c = [w[0], w[1], w[2], w[3], h.operatorAddr(), address(h)];
        for (uint256 i; i < c.length; ++i) {
            if (ex.isOperator(c[i])) {
                assertTrue(
                    c[i] != ex.admin() && c[i] != ex.pendingAdmin() && c[i] != ex.resolver() && c[i] != ex.TREASURY(),
                    "O8"
                );
            }
        }
        assertTrue(ex.isOperator(h.operatorAddr()));
    }

    function afterInvariant() public {
        emit log_named_uint("successful matches", h.successfulMatches());
        emit log_named_uint("successful mints", h.successfulSets());
        emit log_named_uint("successful merges", h.successfulMerges());
    }

    /// @dev The fuzzer must actually trade, mint and merge, or every invariant above passes on an empty run. After the
    /// run, this directly exercises one of each so the handler's own checks run at least once, and fails if they cannot.
    function test_handlerReachesEveryKindOfMatch() public {
        // a seed sweep through the handler's own actions: some must settle
        for (
            uint256 s = 1;
            s <= 400 && (h.successfulMatches() < 6 || h.successfulSets() == 0 || h.successfulMerges() == 0);
            ++s
        ) {
            h.act_deposit(s, 500e6);
            h.act_mint(s, s, 50e6 + s * 10_000);
            h.act_direct(s, s >> 2, uint256(keccak256(abi.encode(s))));
            h.act_set(uint256(keccak256(abi.encode(s, "set"))));
            h.act_merge(s, s, 1e6);
        }
        assertGe(h.successfulMatches(), 6, "direct and set matches settle in the handler");
        assertGt(h.successfulSets(), 0);
        assertGt(h.successfulMerges(), 0);
        assertFalse(h.gMoney());
    }
}
