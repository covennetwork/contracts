// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Script, console} from "forge-std/Script.sol";
import {CovenArb} from "../src/CovenArb.sol";

contract DeployArb is Script {
    uint16 internal constant DEFAULT_FEE_BPS = 1000;

    function run() external returns (CovenArb arb) {
        address owner = vm.envAddress("COVEN_ARB_OWNER");
        address feeRecipient = vm.envAddress("COVEN_ARB_FEE_RECIPIENT");
        uint16 feeBps = SafeCast.toUint16(vm.envOr("COVEN_ARB_FEE_BPS", uint256(DEFAULT_FEE_BPS)));
        bool allowEoaOwner = vm.envOr("COVEN_ALLOW_EOA_OWNER", false);
        require(block.chainid == 5042, "not arc mainnet");
        require(allowEoaOwner || owner.code.length != 0, "owner must be a contract wallet");
        require(feeBps != 0, "arb fee must be non-zero");
        require(feeBps <= 2000, "arb fee cannot exceed 2000 bps");
        vm.startBroadcast();
        arb = new CovenArb(owner, feeRecipient, feeBps);
        vm.stopBroadcast();
        require(arb.owner() == owner, "owner mismatch");
        require(arb.feeBps() == feeBps, "fee mismatch");
        require(arb.feeRecipient() == feeRecipient, "fee recipient mismatch");
        console.log("CovenArb", address(arb));
        console.log("feeBps", feeBps);
    }
}
