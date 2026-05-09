// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MakoPrivateMarketsV1} from "../src/MakoPrivateMarketsV1.sol";

/// @title  DeployPrivateMarketsV1 — broadcast MakoPrivateMarketsV1 to the target chain.
/// @notice Reads credentials from env vars injected by the `with-bw.mjs` wrapper.
/// @dev    Constructor: (usdc, treasury). Same USDC address used by MakoMarketsV4
///         on each chain. Reuses the same treasury wallet as v4 for simpler
///         accounting.
///         Monad testnet USDC: 0x534b2f3A21130d7a60830c2Df862319e593943A3
///         Monad mainnet USDC: 0x754704Bc059F8C67012fEd69BC8A327a5aafb603
contract DeployPrivateMarketsV1 is Script {
    function run() external returns (MakoPrivateMarketsV1 pm) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address treasury = vm.envAddress("TREASURY");
        address usdc = vm.envAddress("USDC_ADDRESS");

        vm.startBroadcast(pk);
        pm = new MakoPrivateMarketsV1(usdc, treasury);
        vm.stopBroadcast();

        console.log("=================================");
        console.log("MakoPrivateMarketsV1 deployed");
        console.log("  address:        ", address(pm));
        console.log("  treasury:       ", pm.treasury());
        console.log("  usdc:           ", address(pm.usdc()));
        console.log("  nextMarketId:   ", pm.nextMarketId());
        console.log("  MIN_STAKE:      ", pm.MIN_STAKE());
        console.log("  POST_CLOSE_GRACE:", pm.POST_CLOSE_GRACE());
        console.log("  PROTOCOL_FEE_BPS:", pm.PROTOCOL_FEE_BPS());
        console.log("  MAX_OPTIONS:    ", pm.MAX_OPTIONS());
        console.log("  MAX_WINNERS:    ", pm.MAX_WINNERS());
        console.log("  MAX_ALLOWLIST:  ", pm.MAX_ALLOWLIST());
        console.log("=================================");
        console.log("Next steps:");
        console.log("  1. Set NEXT_PUBLIC_PRIVATE_MARKETS_ADDRESS in mako-markets/.env.local");
        console.log("  2. Generate ABI: forge inspect MakoPrivateMarketsV1 abi");
        console.log("     and write to mako-markets/src/lib/MakoPrivateMarketsV1.abi.ts");
        console.log("  3. Record deploy block for the indexer's start point");
    }
}
