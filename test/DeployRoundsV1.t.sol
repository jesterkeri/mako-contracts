// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployRoundsV1} from "../script/DeployRoundsV1.s.sol";
import {MakoRoundsV1} from "../src/MakoRoundsV1.sol";
import {IVerifierProxy} from "../src/interfaces/IVerifierProxy.sol";
import {RoundSettlement} from "../src/RoundSettlement.sol";

/// @notice T1.5: the rounds deploy script refuses every wrong environment and every wrong read-back.
///
/// Offline tests cover the creator list, the chain id and every read-back check. The pinned code hashes can
/// only be accepted against the real chain, so those run in the fork half below, which SKIPS without
/// `MAKO_FORK_RPC` exactly as `RoundSettlementFork.t.sol` does:
///
///   MAKO_FORK_RPC=https://testnet-rpc.monad.xyz/ forge test --match-contract DeployRoundsV1 -vvv
contract DeployRoundsV1Test is Test {
    DeployRoundsV1 internal script;

    address internal constant TREASURY = address(0x7EA5);
    address internal constant A = address(0xA11CE);
    address internal constant B = address(0xB0B);
    address internal constant C = address(0xC4A5E);

    function setUp() public {
        script = new DeployRoundsV1();
    }

    function _list(address x, address y, address z) internal pure returns (address[] memory l) {
        l = new address[](3);
        (l[0], l[1], l[2]) = (x, y, z);
    }

    // ---- the creator list ----

    function test_CreatorsAreSortedWhateverTheInputOrder() public view {
        address[] memory s = script.sortedCreators(_list(C, A, B));
        assertEq(s.length, 3);
        assertLt(uint160(s[0]), uint160(s[1]));
        assertLt(uint160(s[1]), uint160(s[2]));
        // Same members: B = 0xB0B sorts first, then A = 0xA11CE, then C = 0xC4A5E.
        assertEq(s[0], B);
        assertEq(s[1], A);
        assertEq(s[2], C);
    }

    function test_EmptyCreatorListIsRefused() public {
        vm.expectRevert(DeployRoundsV1.NoCreators.selector);
        script.sortedCreators(new address[](0));
    }

    function test_ZeroCreatorIsRefused() public {
        vm.expectRevert(DeployRoundsV1.ZeroCreator.selector);
        script.sortedCreators(_list(A, address(0), B));
    }

    function test_DuplicateCreatorIsRefusedNotDropped() public {
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.DuplicateCreator.selector, B));
        script.sortedCreators(_list(B, A, B));
    }

    /// The sorted list is exactly what the constructor accepts: it reverts on anything not strictly ascending.
    function test_SortedListIsAcceptedByTheConstructor() public {
        address[] memory s = script.sortedCreators(_list(C, B, A));
        MakoRoundsV1 r = new MakoRoundsV1(TREASURY, script.USDC(), s);
        assertTrue(r.isCreator(A) && r.isCreator(B) && r.isCreator(C));
    }

    // ---- the chain ----

    function test_RefusesAnyChainButMonadTestnet() public {
        vm.chainId(143);
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.WrongChain.selector, 143));
        script.checkChain();
    }

    function test_RefusesUsdcWithoutThePinnedCode() public {
        vm.etch(script.USDC(), hex"00");
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.WrongUsdcCode.selector, keccak256(hex"00")));
        script.checkUsdc();
    }

    function test_RefusesAVerifierWithoutThePinnedCode() public {
        vm.etch(script.VERIFIER_PROXY(), hex"00");
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.WrongVerifierCode.selector, keccak256(hex"00")));
        script.checkVerifier();
    }

    /// The chain check runs both, so a wrong USDC stops it even on the right chain.
    function test_ChainCheckIncludesTheUsdcCheck() public {
        vm.chainId(10143);
        vm.etch(script.USDC(), hex"00");
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.WrongUsdcCode.selector, keccak256(hex"00")));
        script.checkChain();
    }

    /// The script restates the library's internal constants; they must agree, or the script would check one
    /// verifier while the contract calls another.
    function test_ScriptPinsTheSameVerifierAndFeedAsTheLibrary() public view {
        assertEq(script.VERIFIER_PROXY(), RoundSettlement.VERIFIER_PROXY);
        assertEq(script.FEED_ID(), RoundSettlement.FEED_ID);
    }

    // ---- the read-back ----

    function _deployed(address[] memory sorted) internal returns (MakoRoundsV1) {
        return new MakoRoundsV1(TREASURY, script.USDC(), sorted);
    }

    function test_ReadBackAcceptsTheIntendedDeployment() public {
        address[] memory s = script.sortedCreators(_list(A, B, C));
        script.checkDeployment(_deployed(s), TREASURY, s, 10);
    }

    function test_ReadBackRefusesAnotherTreasury() public {
        address[] memory s = script.sortedCreators(_list(A, B, C));
        MakoRoundsV1 r = _deployed(s);
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.ReadBackMismatch.selector, "TREASURY"));
        script.checkDeployment(r, address(0xBAD), s, 10);
    }

    function test_ReadBackRefusesAnotherUsdc() public {
        address[] memory s = script.sortedCreators(_list(A, B, C));
        MakoRoundsV1 r = new MakoRoundsV1(TREASURY, address(0xBAD), s);
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.ReadBackMismatch.selector, "USDC"));
        script.checkDeployment(r, TREASURY, s, 10);
    }

    function test_ReadBackRefusesAnotherCreatorSet() public {
        address[] memory deployedWith = script.sortedCreators(_list(A, B, C));
        address[] memory intended = new address[](2);
        (intended[0], intended[1]) = (A, B);
        MakoRoundsV1 r = _deployed(deployedWith);
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.ReadBackMismatch.selector, "CREATORS_HASH"));
        script.checkDeployment(r, TREASURY, intended, 10);
    }

    /// The operator must state the cap T0.1c chose; a different number stops the deployment.
    function test_ReadBackRefusesAnUnconfirmedCap() public {
        address[] memory s = script.sortedCreators(_list(A, B, C));
        MakoRoundsV1 r = _deployed(s);
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.ReadBackMismatch.selector, "MAX_ACTIVE_ROUNDS"));
        script.checkDeployment(r, TREASURY, s, 5);
    }

    function test_ReadBackRefusesAnAddressWithNoCode() public {
        address[] memory s = script.sortedCreators(_list(A, B, C));
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.ReadBackMismatch.selector, "code"));
        script.checkDeployment(MakoRoundsV1(address(0xDEAD)), TREASURY, s, 10);
    }

    // ---- against the real chain (skips without MAKO_FORK_RPC) ----

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("MAKO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return false;
        // The script instance from setUp lives in the local state; carry it onto the fork.
        vm.makePersistent(address(script));
        vm.createSelectFork(rpc);
        return true;
    }

    function test_ForkPinnedContractsMatchTheLiveChain() public {
        vm.skip(!_fork(), "MAKO_FORK_RPC is not set: fork test SKIPPED, which is NOT a pass");
        script.checkChain();
    }

    function test_ForkRefusesAVerifierWithOtherCode() public {
        vm.skip(!_fork(), "MAKO_FORK_RPC is not set: fork test SKIPPED, which is NOT a pass");
        address v = script.VERIFIER_PROXY();
        vm.etch(v, bytes.concat(v.code, hex"00"));
        bytes32 tampered = v.codehash;
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.WrongVerifierCode.selector, tampered));
        script.checkChain();
    }

    function test_ForkRefusesAFeeManager() public {
        vm.skip(!_fork(), "MAKO_FORK_RPC is not set: fork test SKIPPED, which is NOT a pass");
        address v = script.VERIFIER_PROXY();
        vm.mockCall(v, abi.encodeCall(IVerifierProxy.s_feeManager, ()), abi.encode(address(0xFEE)));
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.VerifierFeeManagerSet.selector, address(0xFEE)));
        script.checkChain();
    }

    function test_ForkRefusesAnAccessController() public {
        vm.skip(!_fork(), "MAKO_FORK_RPC is not set: fork test SKIPPED, which is NOT a pass");
        address v = script.VERIFIER_PROXY();
        vm.mockCall(v, abi.encodeCall(IVerifierProxy.s_accessController, ()), abi.encode(address(0xACC)));
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.VerifierAccessControllerSet.selector, address(0xACC)));
        script.checkChain();
    }

    function test_ForkRefusesAnotherVerifierVersion() public {
        vm.skip(!_fork(), "MAKO_FORK_RPC is not set: fork test SKIPPED, which is NOT a pass");
        address v = script.VERIFIER_PROXY();
        vm.mockCall(v, abi.encodeCall(IVerifierProxy.typeAndVersion, ()), abi.encode("VerifierProxy 2.1.0"));
        vm.expectRevert(abi.encodeWithSelector(DeployRoundsV1.WrongVerifierVersion.selector, "VerifierProxy 2.1.0"));
        script.checkChain();
    }

    /// The whole script, end to end, as a dry run against the live chain: checks, simulated deploy, read-back
    /// and the receipt printed (not written, since this is not a broadcast).
    function test_ForkFullDryRun() public {
        vm.skip(!_fork(), "MAKO_FORK_RPC is not set: fork test SKIPPED, which is NOT a pass");
        vm.setEnv("ROUNDS_TREASURY", vm.toString(TREASURY));
        vm.setEnv("ROUNDS_CREATORS", string.concat(vm.toString(C), ",", vm.toString(A), ",", vm.toString(B)));
        vm.setEnv("ROUNDS_EXPECTED_CAP", "10");
        MakoRoundsV1 r = script.run();
        assertEq(r.TREASURY(), TREASURY);
        assertTrue(r.isCreator(A) && r.isCreator(B) && r.isCreator(C));
        assertEq(r.roundCount(), 0);
    }
}
