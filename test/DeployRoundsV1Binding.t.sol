// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployRoundsV1} from "../script/DeployRoundsV1.s.sol";
import {DeployRoundsV1WithInputs} from "./DeployRoundsV1WithInputs.sol";
import {MakoRoundsV1} from "../src/MakoRoundsV1.sol";
import {BroadcastRecord} from "./BroadcastRecord.sol";

/// @notice Adversary pass on T1.5 (5d7e96e), adopted: attacks on the transaction binding of `verifyDeployment`.
/// Its defect (a record whose transaction is not on the real chain was accepted) is fixed by `checkOnChain`,
/// which reads the real chain through the pinned `monad_testnet` endpoint; the tests after the defect section
/// cover that check on a stand-in chain offline and against the real chain on the fork.
///   offline: forge test --match-contract DeployRoundsV1BindingTest -vvv
///   fork:    MAKO_FORK_RPC=https://testnet-rpc.monad.xyz/ forge test --network monad --match-contract DeployRoundsV1BindingTest -vvv
contract DeployRoundsV1BindingTest is Test {
    DeployRoundsV1WithInputs internal script;

    address internal constant TREASURY = address(0x7EA5);
    address internal constant A = address(0xA11CE);
    address internal constant B = address(0xB0B);
    bytes32 internal constant HASH = keccak256("the deploy transaction");

    function setUp() public {
        script = new DeployRoundsV1WithInputs();
        string[] memory c = new string[](2);
        (c[0], c[1]) = (vm.toString(B), vm.toString(A));
        script.setInputs(vm.toString(TREASURY), c, 10);
    }

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("MAKO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return false;
        vm.makePersistent(address(script));
        vm.createSelectFork(rpc);
        return true;
    }

    // ---- parser attacks that the code survives (kept as regression evidence) ----

    /// Forge writes receipt addresses in lowercase and status/block as short hex ("0x1"), as seen in a real
    /// run-latest.json produced by `forge script --broadcast` against a local anvil fork of chain 10143.
    function test_RecordAcceptsForgeShapedLowercaseAndShortHex() public view {
        string memory rec = string.concat(
            '{"transactions":[{"hash":"',
            vm.toString(HASH),
            '","transactionType":"CREATE","contractName":"MakoRoundsV1","contractAddress":"0x00000000000000000000000000000000000a11ce"}],',
            '"receipts":[{"transactionHash":"',
            vm.toString(HASH),
            '","status":"0x1","blockNumber":"0x415e8e7","contractAddress":"0x00000000000000000000000000000000000a11ce"}]}'
        );
        (bytes32 h, uint256 b) = script.deployTransactionIn(rec, A);
        assertEq(h, HASH);
        assertEq(b, 0x415e8e7);
    }

    /// A MakoRoundsV1 that appears only as a nested `additionalContracts` entry of another CREATE is not this
    /// script's own CREATE of MakoRoundsV1.
    function test_RecordRefusesANestedAdditionalContract() public {
        string memory rec = string.concat(
            '{"transactions":[{"hash":"',
            vm.toString(HASH),
            '","transactionType":"CREATE","contractName":"Factory","contractAddress":"',
            vm.toString(B),
            '","additionalContracts":[{"transactionType":"CREATE","contractName":"MakoRoundsV1","address":"',
            vm.toString(A),
            '"}]}],"receipts":[',
            BroadcastRecord.receipt(HASH, 1, 7, B),
            "]}"
        );
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.NoDeployTransaction.selector, A));
        script.deployTransactionIn(rec, A);
    }

    /// The first CREATE entry for the address decides; a later, successful duplicate cannot rescue a failed one.
    function test_RecordDuplicateCreateFirstFailedIsRefused() public {
        bytes32 h2 = keccak256("a second entry");
        string memory rec = BroadcastRecord.record(
            string.concat(
                BroadcastRecord.tx_(HASH, "CREATE", "MakoRoundsV1", A),
                ",",
                BroadcastRecord.tx_(h2, "CREATE", "MakoRoundsV1", A)
            ),
            string.concat(BroadcastRecord.receipt(HASH, 0, 7, A), ",", BroadcastRecord.receipt(h2, 1, 8, A))
        );
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.NoDeployTransaction.selector, A));
        script.deployTransactionIn(rec, A);
    }

    // ---- the defect ----

    /// The receipt records a deploy transaction and block, but neither is checked against the chain the
    /// receipt names: only forge's local file is read. A rehearsal broadcast to an anvil fork of Monad testnet
    /// (anvil keeps chain id 10143, so forge writes broadcast/DeployRoundsV1.s.sol/10143/run-latest.json)
    /// leaves a record whose transaction never existed on chain 10143, and verifyDeployment against that
    /// fork writes a "verified deployment" receipt for chain 10143. Here the genuine contract is deployed
    /// locally on a fork of the real chain, exactly as on such a rehearsal, and the record names a hash the
    /// real chain does not have. The real chain's own answer is asserted first, so the test cannot pass
    /// vacuously: eth_getTransactionReceipt for HASH is null on Monad testnet (checked 2026-10-06 with
    /// `cast rpc eth_getTransactionReceipt <HASH> --rpc-url https://testnet-rpc.monad.xyz/` -> null).
    function test_ForkRefusesARecordWhoseTransactionIsNotOnChain() public {
        vm.skip(!_fork(), "MAKO_FORK_RPC is not set: fork test SKIPPED, which is NOT a pass");
        bytes memory onChain = vm.rpc("eth_getTransactionReceipt", string.concat('["', vm.toString(HASH), '"]'));
        // vm.rpc encodes a JSON null result as 32 zero bytes; a real receipt object encodes to far more.
        assertEq(onChain, new bytes(32), "precondition: HASH must not be a transaction on chain 10143");

        (address treasury, address[] memory sorted,) = script.readInputs();
        MakoRoundsV1 r = new MakoRoundsV1{salt: keccak256("binding adversary")}(treasury, script.USDC(), sorted);
        string memory path = script.receiptPath(address(r));
        if (vm.exists(path)) vm.removeFile(path);
        script.setBroadcastRecord(BroadcastRecord.created(address(r), HASH, 1, 70000123));

        try script.verifyDeployment(r) {} catch {}
        bool written = vm.exists(path);
        if (written) vm.removeFile(path);
        assertFalse(written, "verified-deployment receipt written for a CREATE transaction that is not on chain 10143");
    }

    // ---- the real-chain check (fix) ----

    uint256 internal constant BLK = 70000123; // DeployRoundsV1WithInputs.FAKE_DEPLOY_BLOCK

    function test_OnChainCheckAcceptsWhatTheChainConfirms() public {
        bytes32 code = keccak256("code");
        script.setChainView(true, keccak256(""), code);
        script.checkOnChain(A, HASH, BLK, code);
    }

    function test_OnChainCheckRefusesATransactionTheChainDoesNotHave() public {
        script.setChainView(false, keccak256(""), keccak256("code"));
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.NotOnChain.selector, "transaction"));
        script.checkOnChain(A, HASH, BLK, keccak256("code"));
    }

    function test_OnChainCheckRefusesCodeThatExistedBeforeTheDeployBlock() public {
        script.setChainView(true, keccak256("code"), keccak256("code"));
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.NotOnChain.selector, "code before the deploy block"));
        script.checkOnChain(A, HASH, BLK, keccak256("code"));
    }

    function test_OnChainCheckRefusesOtherCodeAtTheDeployBlock() public {
        script.setChainView(true, keccak256(""), keccak256("other code"));
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.NotOnChain.selector, "code at the deploy block"));
        script.checkOnChain(A, HASH, BLK, keccak256("code"));
    }

    function test_OnChainCheckRefusesBlockZero() public {
        script.setChainView(true, keccak256(""), keccak256("code"));
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.NotOnChain.selector, "block"));
        script.checkOnChain(A, HASH, 0, keccak256("code"));
    }

    /// The real reads, against Monad testnet itself: a transaction that exists (block 68548134, status 1, read
    /// 2026-10-06), one that does not, the live V4's code by hash, and an address with no code.
    function test_ForkRealChainReadsAreTruthful() public {
        vm.skip(!_fork(), "MAKO_FORK_RPC is not set: fork test SKIPPED, which is NOT a pass");
        assertTrue(script.onChainReceiptExists(0x5d8e177a4206fc7d9acaf0641f04f4c880260cbf11eb7a835a1e5c7c9a1460be));
        assertFalse(script.onChainReceiptExists(HASH));
        assertEq(
            script.onChainCodeHash(0xbC5A58487D7949dA2B76aC84AfC032fD0aa26195, block.number),
            0x0fc0b5588ccd94ced09091e88ac19fb106c4521b38b11c9f8a276073f2779523
        );
        assertEq(script.onChainCodeHash(address(0xD1FF), block.number), keccak256(""));
    }

    function test_QuantityHasNoLeadingZeros() public view {
        assertEq(script.quantity(0), "0x0");
        assertEq(script.quantity(1), "0x1");
        assertEq(script.quantity(255), "0xff");
        assertEq(script.quantity(68548134), "0x415f626");
        assertEq(script.quantity(type(uint256).max), string.concat("0x", _fs(64)));
    }

    function _fs(uint256 n) internal pure returns (string memory out) {
        for (uint256 i = 0; i < n; i++) {
            out = string.concat(out, "f");
        }
    }
}
