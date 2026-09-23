// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {Script, console} from "forge-std/Script.sol";
import {CovenSessionFactory} from "../src/CovenSessionFactory.sol";

contract DeployFactory is Script {
    function run() external returns (CovenSessionFactory factory) {
        address router = vm.envAddress("COVEN_ROUTER");
        address lens = vm.envAddress("COVEN_LENS");
        require(block.chainid == 5042, "not arc mainnet");
        require(router.code.length != 0, "router not deployed");
        require(lens.code.length != 0, "lens not deployed");
        vm.startBroadcast();
        factory = new CovenSessionFactory(router, lens);
        vm.stopBroadcast();
        require(factory.ROUTER() == router && factory.LENS() == lens, "factory misconfigured");
        console.log("CovenSessionFactory", address(factory));
    }
}
