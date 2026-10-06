// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployRoundsV1} from "../script/DeployRoundsV1.s.sol";
import {DeployRoundsV1WithInputs} from "./DeployRoundsV1WithInputs.sol";
import {MakoRoundsV1} from "../src/MakoRoundsV1.sol";
import {BroadcastRecord} from "./BroadcastRecord.sol";

/// @notice Codex T1.5 r1 (MAJOR): `verifyDeployment` wrote a "verified deployment" receipt for any address
/// whose getters answered as expected, so a look-alike with other code, or a typo'd address of another
/// deployment, could become an authoritative receipt. The receipt now needs (1) the runtime code to equal
/// this build's MakoRoundsV1 for the same constructor inputs and (2) the address to be this script's own
/// landed CREATE in forge's broadcast record. Fork tests skip without MAKO_FORK_RPC, which is NOT a pass:
///   MAKO_FORK_RPC=https://testnet-rpc.monad.xyz/ forge test --network monad --match-contract DeployRoundsV1Identity -vvv
contract DeployRoundsV1IdentityTest is Test {
    DeployRoundsV1WithInputs internal script;

    address internal constant TREASURY = address(0x7EA5);
    address internal constant A = address(0xA11CE);
    address internal constant B = address(0xB0B);
    address internal constant LOOK_ALIKE = address(0x1009A11CE);
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

    /// A receipt left by an earlier aborted run (or a mutation run) must not decide a test either way.
    function _clear(address at) internal {
        string memory path = script.receiptPath(at);
        if (vm.exists(path)) vm.removeFile(path);
    }

    function _genuine(string memory tag) internal returns (MakoRoundsV1 r, address treasury, address[] memory sorted) {
        (treasury, sorted,) = script.readInputs();
        // Each test its own CREATE2 address: tests run in parallel, and two deployments from the same default
        // test address and nonce would share (and delete) one receipt file.
        r = new MakoRoundsV1{salt: keccak256(bytes(tag))}(treasury, script.USDC(), sorted);
    }

    /// Codex's demonstration: the genuine runtime with one unreachable byte appended, at another address,
    /// with the genuine storage. Every getter answers exactly as the genuine one does.
    function _lookAlike(MakoRoundsV1 r) internal returns (MakoRoundsV1) {
        vm.etch(LOOK_ALIKE, abi.encodePacked(address(r).code, hex"00"));
        vm.copyStorage(address(r), LOOK_ALIKE);
        return MakoRoundsV1(LOOK_ALIKE);
    }

    // ---- code identity, offline ----

    function test_CodeIdentityAcceptsTheGenuineContract() public {
        (MakoRoundsV1 r, address treasury, address[] memory sorted) =
            _genuine("test_CodeIdentityAcceptsTheGenuineContract");
        assertEq(script.checkCodeIdentity(r, treasury, sorted), address(r).codehash);
    }

    /// The look-alike passes every configuration read-back, which is why code identity is needed at all.
    function test_LookAlikePassesTheReadBackButNotCodeIdentity() public {
        (MakoRoundsV1 r, address treasury, address[] memory sorted) =
            _genuine("test_LookAlikePassesTheReadBackButNotCodeIdentity");
        MakoRoundsV1 fake = _lookAlike(r);
        script.checkDeployment(fake, treasury, sorted, 10);
        vm.expectRevert(
            abi.encodeWithSelector(DeployRoundsV1.WrongRuntimeCode.selector, LOOK_ALIKE.codehash, address(r).codehash)
        );
        script.checkCodeIdentity(fake, treasury, sorted);
    }

    /// The same source deployed for another treasury is other code (immutables are in the runtime).
    function test_CodeIdentityRefusesTheSameSourceWithOtherInputs() public {
        (, address treasury, address[] memory sorted) = _genuine("test_CodeIdentityRefusesTheSameSourceWithOtherInputs");
        MakoRoundsV1 other = new MakoRoundsV1(address(0xBEEF), script.USDC(), sorted);
        vm.expectRevert();
        script.checkCodeIdentity(other, treasury, sorted);
    }

    // ---- the broadcast record, offline ----

    function test_RecordGivesTheCreateTransactionAndItsBlock() public view {
        (bytes32 h, uint256 b) = script.deployTransactionIn(BroadcastRecord.created(A, HASH, 1, 70000123), A);
        assertEq(h, HASH);
        assertEq(b, 70000123);
    }

    function test_RecordRefusesAnAddressItDidNotCreate() public {
        string memory rec = BroadcastRecord.created(B, HASH, 1, 7);
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.NoDeployTransaction.selector, A));
        script.deployTransactionIn(rec, A);
    }

    function test_RecordRefusesAFailedCreate() public {
        string memory rec = BroadcastRecord.created(A, HASH, 0, 7);
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.NoDeployTransaction.selector, A));
        script.deployTransactionIn(rec, A);
    }

    function test_RecordRefusesACreateWithNoReceipt() public {
        string memory rec = BroadcastRecord.record(BroadcastRecord.tx_(HASH, "CREATE", "MakoRoundsV1", A), "");
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.NoDeployTransaction.selector, A));
        script.deployTransactionIn(rec, A);
    }

    function test_RecordRefusesAReceiptForAnotherAddress() public {
        string memory rec = BroadcastRecord.record(
            BroadcastRecord.tx_(HASH, "CREATE", "MakoRoundsV1", A), BroadcastRecord.receipt(HASH, 1, 7, B)
        );
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.NoDeployTransaction.selector, A));
        script.deployTransactionIn(rec, A);
    }

    function test_RecordRefusesAnotherContractAtTheAddress() public {
        string memory rec = BroadcastRecord.record(
            BroadcastRecord.tx_(HASH, "CREATE", "SomethingElse", A), BroadcastRecord.receipt(HASH, 1, 7, A)
        );
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.NoDeployTransaction.selector, A));
        script.deployTransactionIn(rec, A);
    }

    function test_RecordRefusesACallRatherThanACreate() public {
        string memory rec = BroadcastRecord.record(
            BroadcastRecord.tx_(HASH, "CALL", "MakoRoundsV1", A), BroadcastRecord.receipt(HASH, 1, 7, A)
        );
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.NoDeployTransaction.selector, A));
        script.deployTransactionIn(rec, A);
    }

    /// The CREATE need not be the first entry, and receipts are matched by hash, not by position.
    function test_RecordFindsTheCreateAmongOtherTransactions() public view {
        bytes32 other = keccak256("an earlier call");
        string memory rec = BroadcastRecord.record(
            string.concat(
                BroadcastRecord.tx_(other, "CALL", "", B), ",", BroadcastRecord.tx_(HASH, "CREATE", "MakoRoundsV1", A)
            ),
            string.concat(BroadcastRecord.receipt(HASH, 1, 9, A), ",", BroadcastRecord.receipt(other, 1, 8, B))
        );
        (bytes32 h, uint256 b) = script.deployTransactionIn(rec, A);
        assertEq(h, HASH);
        assertEq(b, 9);
    }

    // ---- the whole of verifyDeployment, on the fork ----

    /// Codex's regression: the look-alike, with a broadcast record naming it, is refused before any receipt.
    function test_ForkVerifyDeploymentRefusesALookAlike() public {
        vm.skip(!_fork(), "MAKO_FORK_RPC is not set: fork test SKIPPED, which is NOT a pass");
        (MakoRoundsV1 r,,) = _genuine("test_ForkVerifyDeploymentRefusesALookAlike");
        MakoRoundsV1 fake = _lookAlike(r);
        _clear(LOOK_ALIKE);
        script.setBroadcastRecord(BroadcastRecord.created(LOOK_ALIKE, HASH, 1, 7));
        vm.expectRevert(
            abi.encodeWithSelector(DeployRoundsV1.WrongRuntimeCode.selector, LOOK_ALIKE.codehash, address(r).codehash)
        );
        script.verifyDeployment(fake);
        assertFalse(vm.exists(script.receiptPath(LOOK_ALIKE)), "a receipt was written for the look-alike");
    }

    /// The genuine code at an address the broadcast did not create (a typo'd address of another deployment of
    /// the same build) is refused too.
    function test_ForkVerifyDeploymentRefusesAnUnrecordedAddress() public {
        vm.skip(!_fork(), "MAKO_FORK_RPC is not set: fork test SKIPPED, which is NOT a pass");
        (MakoRoundsV1 r,,) = _genuine("test_ForkVerifyDeploymentRefusesAnUnrecordedAddress");
        _clear(address(r));
        script.setBroadcastRecord(BroadcastRecord.created(address(0xD1FF), HASH, 1, 7));
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.NoDeployTransaction.selector, address(r)));
        script.verifyDeployment(r);
        assertFalse(vm.exists(script.receiptPath(address(r))), "a receipt was written for an unrecorded address");
    }

    /// The honest path writes the receipt, carrying the expected code hash and the CREATE transaction.
    function test_ForkVerifyDeploymentRecordsCodeAndTransaction() public {
        vm.skip(!_fork(), "MAKO_FORK_RPC is not set: fork test SKIPPED, which is NOT a pass");
        (MakoRoundsV1 r,,) = _genuine("test_ForkVerifyDeploymentRecordsCodeAndTransaction");
        script.setBroadcastRecord(BroadcastRecord.created(address(r), HASH, 1, 70000123));
        // The contract exists only on the local fork, so the real chain's answers are stood in.
        script.setChainCreation(address(r), address(r).codehash);
        script.verifyDeployment(r);
        string memory path = script.receiptPath(address(r));
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonBytes32(json, ".deployTransaction"), HASH);
        assertEq(vm.parseJsonUint(json, ".deployBlock"), 70000123);
        assertEq(vm.parseJsonBytes32(json, ".expectedRuntimeCodeHash"), address(r).codehash);
        assertEq(vm.parseJsonBytes32(json, ".runtimeCodeHash"), address(r).codehash);
        vm.removeFile(path);
    }
}
