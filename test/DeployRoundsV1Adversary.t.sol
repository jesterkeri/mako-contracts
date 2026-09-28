// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployRoundsV1} from "../script/DeployRoundsV1.s.sol";
import {DeployRoundsV1WithInputs} from "./DeployRoundsV1WithInputs.sol";
import {MakoRoundsV1} from "../src/MakoRoundsV1.sol";
import {IVerifierProxy} from "../src/interfaces/IVerifierProxy.sol";

/// @notice Adversary pass on T1.5 (2026-09-28), adopted: the deploy script's refusals exercised through
/// `run()` and `verifyDeployment()` themselves, plus the checksum rule that pass showed was missing.
///
/// `DeployRoundsV1.t.sol` tests every check as a helper (`checkChain`, `checkDeployment`, ...) but never
/// shows that `run()` calls them, so deleting `checkChain();` or `checkDeployment(...)` from `run()`, or
/// writing the receipt on a dry run, leaves that whole suite green, offline and on the fork. The tests
/// below pass on the current script and fail on each of those mutants. The fork half skips without
/// `MAKO_FORK_RPC`, like the suite it extends:
///
///   MAKO_FORK_RPC=https://testnet-rpc.monad.xyz/ forge test --network monad --match-contract DeployRoundsV1Adversary
contract DeployRoundsV1AdversaryTest is Test {
    DeployRoundsV1WithInputs internal script;

    address internal constant TREASURY = address(0x7EA5);
    address internal constant A = address(0xA11CE);
    address internal constant B = address(0xB0B);

    function setUp() public {
        script = new DeployRoundsV1WithInputs();
    }

    function _pair() internal pure returns (string[] memory c) {
        c = new string[](2);
        (c[0], c[1]) = (vm.toString(B), vm.toString(A));
    }

    function _env(string memory treasury, string memory cap) internal {
        script.setInputs(treasury, _pair(), vm.parseUint(cap));
    }

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("MAKO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return false;
        vm.makePersistent(address(script));
        vm.createSelectFork(rpc);
        return true;
    }

    // ---- offline: run() reaches the chain check before it deploys ----

    /// Kills "delete `checkChain();` from run()": offline the chain is 31337, so run() must stop there.
    function test_RunRefusesAnotherChainBeforeDeploying() public {
        _env(vm.toString(TREASURY), "10");
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.WrongChain.selector, block.chainid));
        script.run();
    }

    // ---- fork: run() refuses a tampered verifier, an unconfirmed cap, and writes nothing on a dry run ----

    /// Kills "delete `checkChain();` from run()" on the live chain.
    function test_ForkRunRefusesAFeeManager() public {
        vm.skip(!_fork(), "MAKO_FORK_RPC is not set: fork test SKIPPED, which is NOT a pass");
        _env(vm.toString(TREASURY), "10");
        vm.mockCall(
            script.VERIFIER_PROXY(), abi.encodeCall(IVerifierProxy.s_feeManager, ()), abi.encode(address(0xFEE))
        );
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.VerifierFeeManagerSet.selector, address(0xFEE)));
        script.run();
    }

    /// Kills "delete `checkDeployment(...)` from run()": the operator states 9, the source says 10.
    function test_ForkRunRefusesAnUnconfirmedCap() public {
        vm.skip(!_fork(), "MAKO_FORK_RPC is not set: fork test SKIPPED, which is NOT a pass");
        _env(vm.toString(TREASURY), "9");
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.ReadBackMismatch.selector, "MAX_ACTIVE_ROUNDS"));
        script.run();
    }

    /// run() never writes a receipt: forge executes it before sending anything, so a receipt there could
    /// outlive a failed broadcast.
    function test_ForkRunWritesNoReceipt() public {
        vm.skip(!_fork(), "MAKO_FORK_RPC is not set: fork test SKIPPED, which is NOT a pass");
        _env(vm.toString(TREASURY), "10");
        MakoRoundsV1 r = script.run();
        string memory path = script.receiptPath(address(r));
        // removeFile succeeds only if the file exists, so a receipt left by the dry run above fails the test
        // (and is cleaned up). fs_permissions grant ./deployments write but not read, so vm.exists is refused.
        try vm.removeFile(path) {
            fail("run() wrote a receipt");
        } catch {}
    }

    /// A treasury typed with one wrong hex digit fails its EIP-55 checksum, but forge's envAddress accepts it,
    /// and TREASURY is immutable with no setter (SPEC §4, §8), so every protocol fee goes to the typo forever.
    /// Intended: 0x7ea5C0FFEe00000000000000000000000000BeeF. Typed: ...BeeE, whose correct checksum form is
    /// 0x7Ea5c0fFEE00000000000000000000000000beEE (`cast to-check-sum-address`), so the typed string is not a
    /// valid checksummed address.
    function test_RunRefusesATreasuryWithABadChecksum() public {
        _env("0x7ea5C0FFEe00000000000000000000000000BeeE", "10");
        vm.expectRevert(
            abi.encodeWithSelector(DeployRoundsV1.NotChecksummed.selector, "0x7ea5C0FFEe00000000000000000000000000BeeE")
        );
        script.run();
    }

    /// All-lowercase has no checksum to catch a typo, so it is refused for these immutable addresses too.
    function test_RunRefusesAnAllLowercaseTreasury() public {
        string memory lower = "0x7ea5c0ffee00000000000000000000000000beee";
        _env(lower, "10");
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.NotChecksummed.selector, lower));
        script.run();
    }

    function test_RunRefusesACreatorWithABadChecksum() public {
        string[] memory c = new string[](2);
        (c[0], c[1]) = (vm.toString(B), "0x7ea5C0FFEe00000000000000000000000000BeeE");
        script.setInputs(vm.toString(TREASURY), c, 10);
        vm.expectRevert(
            abi.encodeWithSelector(DeployRoundsV1.NotChecksummed.selector, "0x7ea5C0FFEe00000000000000000000000000BeeE")
        );
        script.run();
    }

    /// The script's own zero-treasury refusal, reached through run() before anything else.
    function test_RunRefusesAZeroTreasury() public {
        _env(vm.toString(address(0)), "10");
        vm.expectRevert(DeployRoundsV1.ZeroTreasury.selector);
        script.run();
    }

    function test_ChecksummedAddressWithSurroundingSpacesIsAccepted() public view {
        assertEq(
            script.checksummed("  0x7Ea5c0fFEE00000000000000000000000000beEE "),
            address(0x7Ea5c0fFEE00000000000000000000000000beEE)
        );
    }

    function test_VerifyDeploymentRefusesAnotherChain() public {
        _env(vm.toString(TREASURY), "10");
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.WrongChain.selector, block.chainid));
        script.verifyDeployment(MakoRoundsV1(address(0xDEAD)));
    }

    /// The receipt is written only by verifyDeployment, from a contract that exists on the chain.
    function test_ForkVerifyDeploymentWritesTheReceipt() public {
        vm.skip(!_fork(), "MAKO_FORK_RPC is not set: fork test SKIPPED, which is NOT a pass");
        _env(vm.toString(TREASURY), "10");
        (address treasury, address[] memory sorted,) = script.readInputs();
        MakoRoundsV1 r = new MakoRoundsV1(treasury, script.USDC(), sorted);
        script.verifyDeployment(r);
        // removeFile succeeds only if the receipt exists, and cleans it up.
        vm.removeFile(script.receiptPath(address(r)));
    }

    /// A broadcast that never landed leaves no code at the address, so no receipt can be written for it.
    function test_ForkVerifyDeploymentRefusesAnAddressWithNoContract() public {
        vm.skip(!_fork(), "MAKO_FORK_RPC is not set: fork test SKIPPED, which is NOT a pass");
        _env(vm.toString(TREASURY), "10");
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.ReadBackMismatch.selector, "code"));
        script.verifyDeployment(MakoRoundsV1(address(0xDEAD)));
    }
}
