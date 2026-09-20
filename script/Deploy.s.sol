// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Script, console} from "forge-std/Script.sol";
import {CovenRouter} from "../src/CovenRouter.sol";
import {CovenLens} from "../src/CovenLens.sol";
contract Deploy is Script {
    function run() external returns (CovenRouter router, CovenLens lens) {
        address owner = vm.envAddress("COVEN_OWNER");
        address feeRecipient = vm.envAddress("COVEN_FEE_RECIPIENT");
        address guardian = vm.envAddress("COVEN_GUARDIAN");
        uint16 platformFeeBps = SafeCast.toUint16(vm.envUint("COVEN_PLATFORM_FEE_BPS"));
        require(block.chainid == 5042, "not arc mainnet");
        require(owner.code.length != 0, "owner must be a contract wallet");
        vm.startBroadcast();
        router = new CovenRouter(owner, feeRecipient, guardian, platformFeeBps);
        lens = new CovenLens(router);
        vm.stopBroadcast();
        require(router.owner() == owner && router.platformFeeBps() == platformFeeBps, "router misconfigured");
        require(address(lens.router()) == address(router), "lens misconfigured");
        console.log("CovenRouter", address(router));
        console.log("CovenLens", address(lens));
    }
}
