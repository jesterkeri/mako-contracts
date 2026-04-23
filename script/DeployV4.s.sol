// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MakoMarketsV4} from "../src/MakoMarketsV4.sol";

/// @title  DeployV4 — broadcast MakoMarketsV4 to the target chain.
/// @notice Reads credentials from env vars injected by the `with-bw.mjs` wrapper.
/// @dev    USDC address MUST be the canonical 6-decimal USDC on the target chain.
///         Monad testnet:  0x534b2f3A21130d7a60830c2Df862319e593943A3
///         Monad mainnet:  0x754704Bc059F8C67012fEd69BC8A327a5aafb603
///         The contract constructor verifies `decimals() == 6`, so a wrong address
///         aborts deployment before any funds are committed.
contract DeployV4 is Script {
    function run() external returns (MakoMarketsV4 mako) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address treasury = vm.envAddress("TREASURY");
        address usdc = vm.envAddress("USDC_ADDRESS");

        vm.startBroadcast(pk);
        mako = new MakoMarketsV4(treasury, usdc);
        vm.stopBroadcast();

        console.log("=================================");
        console.log("MakoMarketsV4 deployed");
        console.log("  address:        ", address(mako));
        console.log("  owner:          ", mako.owner());
        console.log("  resolver:       ", mako.resolver());
        console.log("  treasury:       ", mako.treasury());
        console.log("  usdc:           ", address(mako.usdc()));
        console.log("  nextMarketId:   ", mako.nextMarketId());
        console.log("  protocolFeeBps: ", mako.protocolFeeBps());
        console.log("  creatorFeeBps:  ", mako.creatorFeeBps());
        console.log("  minLiquidityBps:", mako.minLiquidityRatioBps());
        console.log("  MIN_BET (USDC): ", mako.MIN_BET());
        console.log("=================================");
        console.log("Next steps:");
        console.log("  1. Set NEXT_PUBLIC_MAKO_ADDRESS in mako-markets/.env.local");
        console.log("  2. Sync v4 ABI to scripts/mako-abi.json + cf-worker/src/mako-abi.json");
        console.log("  3. Record deploy block for NEXT_PUBLIC_MAKO_DEPLOY_BLOCK");
    }
}
