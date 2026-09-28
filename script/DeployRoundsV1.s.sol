// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {MakoRoundsV1} from "../src/MakoRoundsV1.sol";
import {RoundSettlement} from "../src/RoundSettlement.sol";
import {IVerifierProxy} from "../src/interfaces/IVerifierProxy.sol";

/// @title  DeployRoundsV1: deploy MakoRoundsV1 to Monad testnet, KEEPER-ONLY, and write its receipt.
///
/// @notice Settlement path. This bytecode has `settle` (permissionless, run by the keeper) and NO
///         `onReport`: the CRE path waits for the T0.1b spike to pin the forwarder's metadata layout,
///         and arrives as a redeploy (Joshua, 2026-09-28). So there is no forwarder parameter, and N16's
///         "never names `MockKeystoneForwarder`" holds because this deployment names no forwarder at all.
///
///         What it checks BEFORE broadcasting, and refuses to deploy on any failure:
///           - the chain is Monad testnet (10143);
///           - `USDC` has the pinned runtime code hash (N22, SPEC §4);
///           - `VERIFIER_PROXY` has the pinned code hash, `typeAndVersion` "VerifierProxy 2.0.0", and a zero
///             `s_feeManager` and `s_accessController` (N16, SPEC §4, `KNOWN-LIMITS.md` 21);
///           - the creator list is non-empty, free of zero and duplicate addresses (sorted here, since the
///             constructor requires strictly ascending order).
///         And AFTER the simulated deploy, still before anything is broadcast (`forge script` simulates the
///         whole of `run()` first): every constructor-set value reads back as intended, and
///         `MAX_ACTIVE_ROUNDS` equals `ROUNDS_EXPECTED_CAP`, so the operator confirms the cap T0.1c chose
///         rather than inheriting whatever the source says.
///
///         The script never reads a private key. The sender is whatever `forge script` is given:
///
///           ROUNDS_TREASURY=0x... ROUNDS_CREATORS=0xA...,0xB... ROUNDS_EXPECTED_CAP=10 \
///             forge script script/DeployRoundsV1.s.sol --rpc-url monad_testnet --account <keystore>
///             (add --broadcast only when Joshua has said to deploy; without it this is a dry run)
///
///         On a broadcast it writes `deployments/rounds-v1-<chainid>-<address>.json`, the deployment receipt
///         PREFLIGHT asks for. A dry run prints the same fields and writes nothing.
contract DeployRoundsV1 is Script {
    uint256 public constant MONAD_TESTNET = 10143;

    /// SPEC §4: the USDC live V4 uses, read 2026-09-16.
    address public constant USDC = 0x534b2f3A21130d7a60830c2Df862319e593943A3;
    bytes32 public constant USDC_CODEHASH = 0x96215e6049ed615cdc22fea7701e85458a8e51a2df3e7d45e8f9fa1d521b5a78;

    /// SPEC §4: `VerifierProxy` 2.0.0, 7,009 bytes, read 2026-09-18 on two providers. The address itself is
    /// the library's constant, not an input: `RoundSettlement.VERIFIER_PROXY` is `internal`, so it is
    /// restated here and the test suite asserts the two agree.
    address public constant VERIFIER_PROXY = 0x72790f9eB82db492a7DDb6d2af22A270Dcc3Db64;
    bytes32 public constant VERIFIER_CODEHASH = 0x4bd86e898b2952f6f0d20fee037accf52490dbdd9279345cd4b0a7161b5c022b;
    bytes32 public constant FEED_ID = 0x00037da06d56d083fe599397a4769a042d63aa73dc4ef57709d31e9971a5b439;

    error WrongChain(uint256 chainId);
    error WrongUsdcCode(bytes32 found);
    error WrongVerifierCode(bytes32 found);
    error WrongVerifierVersion(string found);
    error VerifierFeeManagerSet(address found);
    error VerifierAccessControllerSet(address found);
    error NoCreators();
    error ZeroCreator();
    error DuplicateCreator(address creator);
    error ZeroTreasury();
    error ReadBackMismatch(string field);

    /// The chain and the two external contracts this deployment depends on, exactly as pinned.
    function checkChain() public view {
        if (block.chainid != MONAD_TESTNET) revert WrongChain(block.chainid);
        checkUsdc();
        checkVerifier();
    }

    /// N22: the token the contract will credit is the pinned USDC, by code hash.
    function checkUsdc() public view {
        if (USDC.codehash != USDC_CODEHASH) revert WrongUsdcCode(USDC.codehash);
    }

    /// N16: the verifier the library calls is the pinned VerifierProxy 2.0.0, with no fee manager and no
    /// access controller (either would make settlement revert, `KNOWN-LIMITS.md` 21).
    function checkVerifier() public view {
        if (VERIFIER_PROXY.codehash != VERIFIER_CODEHASH) revert WrongVerifierCode(VERIFIER_PROXY.codehash);
        IVerifierProxy v = IVerifierProxy(VERIFIER_PROXY);
        string memory version = v.typeAndVersion();
        if (keccak256(bytes(version)) != keccak256("VerifierProxy 2.0.0")) revert WrongVerifierVersion(version);
        if (v.s_feeManager() != address(0)) revert VerifierFeeManagerSet(v.s_feeManager());
        if (v.s_accessController() != address(0)) revert VerifierAccessControllerSet(v.s_accessController());
    }

    /// The constructor requires strictly ascending creators. Sorting here means the operator can list them
    /// in any order, while a zero or repeated address is still refused rather than silently dropped.
    function sortedCreators(address[] memory creators) public pure returns (address[] memory out) {
        if (creators.length == 0) revert NoCreators();
        out = new address[](creators.length);
        for (uint256 i = 0; i < creators.length; i++) {
            address c = creators[i];
            if (c == address(0)) revert ZeroCreator();
            uint256 j = i;
            while (j > 0 && uint160(out[j - 1]) > uint160(c)) {
                out[j] = out[j - 1];
                j--;
            }
            if (j > 0 && out[j - 1] == c) revert DuplicateCreator(c);
            out[j] = c;
        }
    }

    /// Every constructor-set value, read back from the deployed contract.
    function checkDeployment(MakoRoundsV1 rounds, address treasury, address[] memory sorted, uint256 expectedCap)
        public
        view
    {
        if (address(rounds).code.length == 0) revert ReadBackMismatch("code");
        if (rounds.TREASURY() != treasury) revert ReadBackMismatch("TREASURY");
        if (address(rounds.USDC()) != USDC) revert ReadBackMismatch("USDC");
        if (rounds.CREATORS_HASH() != keccak256(abi.encode(sorted))) revert ReadBackMismatch("CREATORS_HASH");
        for (uint256 i = 0; i < sorted.length; i++) {
            if (!rounds.isCreator(sorted[i])) revert ReadBackMismatch("isCreator");
        }
        if (rounds.MAX_ACTIVE_ROUNDS() != expectedCap) revert ReadBackMismatch("MAX_ACTIVE_ROUNDS");
        if (rounds.roundCount() != 0) revert ReadBackMismatch("roundCount");
    }

    function run() external returns (MakoRoundsV1 rounds) {
        address treasury = vm.envAddress("ROUNDS_TREASURY");
        address[] memory sorted = sortedCreators(vm.envAddress("ROUNDS_CREATORS", ","));
        uint256 expectedCap = vm.envUint("ROUNDS_EXPECTED_CAP");
        if (treasury == address(0)) revert ZeroTreasury();

        checkChain();
        vm.startBroadcast();
        rounds = new MakoRoundsV1(treasury, USDC, sorted);
        vm.stopBroadcast();

        // `forge script` simulates all of run() before it broadcasts anything, so a failure here, a wrong
        // cap included, stops the deployment before a transaction is sent.
        checkDeployment(rounds, treasury, sorted, expectedCap);
        _receipt(rounds, treasury, sorted);
    }

    function _receipt(MakoRoundsV1 rounds, address treasury, address[] memory sorted) internal {
        bool broadcast = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast);
        string memory k = "receipt";
        vm.serializeString(k, "kind", broadcast ? "deployment" : "DRY RUN, nothing deployed");
        vm.serializeString(k, "settlementPaths", "settle (keeper, permissionless) only; no onReport, no forwarder");
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "blockNumber", block.number);
        vm.serializeAddress(k, "roundsV1", address(rounds));
        vm.serializeBytes32(k, "runtimeCodeHash", address(rounds).codehash);
        vm.serializeBytes32(k, "creationCodeHash", keccak256(type(MakoRoundsV1).creationCode));
        vm.serializeAddress(k, "treasury", treasury);
        vm.serializeAddress(k, "usdc", USDC);
        vm.serializeBytes32(k, "usdcCodeHash", USDC.codehash);
        vm.serializeAddress(k, "verifierProxy", VERIFIER_PROXY);
        vm.serializeBytes32(k, "verifierProxyCodeHash", VERIFIER_PROXY.codehash);
        IVerifierProxy v = IVerifierProxy(VERIFIER_PROXY);
        vm.serializeString(k, "verifierTypeAndVersion", v.typeAndVersion());
        vm.serializeAddress(k, "verifierFeeManager", v.s_feeManager());
        vm.serializeAddress(k, "verifierAccessController", v.s_accessController());
        vm.serializeBytes32(k, "feedId", FEED_ID);
        vm.serializeAddress(k, "creators", sorted);
        vm.serializeBytes32(k, "creatorsHash", rounds.CREATORS_HASH());
        vm.serializeUint(k, "maxActiveRounds", rounds.MAX_ACTIVE_ROUNDS());
        string memory json = vm.serializeBytes(k, "constructorArgs", abi.encode(treasury, USDC, sorted));

        console.log(json);
        console.log("the deployment transaction itself is in broadcast/DeployRoundsV1.s.sol/<chainid>/run-latest.json");
        if (broadcast) {
            string memory path = string.concat(
                "deployments/rounds-v1-", vm.toString(block.chainid), "-", vm.toString(address(rounds)), ".json"
            );
            vm.writeJson(json, path);
            console.log("receipt written:", path);
        } else {
            console.log("DRY RUN: nothing was broadcast and no receipt was written.");
        }
    }
}
