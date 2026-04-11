// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MakoMarkets} from "../src/MakoMarkets.sol";

contract Deploy is Script {
    function run() external returns (MakoMarkets mako) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address treasury = vm.envAddress("TREASURY");

        vm.startBroadcast(pk);
        mako = new MakoMarkets(treasury);
        vm.stopBroadcast();

        console.log("=================================");
        console.log("MakoMarkets deployed");
        console.log("  address:   ", address(mako));
        console.log("  owner:     ", mako.owner());
        console.log("  resolver:  ", mako.resolver());
        console.log("  treasury:  ", mako.treasury());
        console.log("  nextMarketId:", mako.nextMarketId());
        console.log("=================================");
        console.log("Save this address into your frontend .env as NEXT_PUBLIC_MAKO_ADDRESS");
    }
}
