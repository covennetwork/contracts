// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Script, console} from "forge-std/Script.sol";
import {CovenRouter} from "../src/CovenRouter.sol";
import {CovenLens} from "../src/CovenLens.sol";
import {ICovenRouter} from "../src/interfaces/ICovenRouter.sol";

contract Deploy is Script {
    function run() external returns (CovenRouter router, CovenLens lens) {
        address owner = vm.envAddress("COVEN_OWNER");
        address feeRecipient = vm.envAddress("COVEN_FEE_RECIPIENT");
        address guardian = vm.envAddress("COVEN_GUARDIAN");
        uint16 platformFeeBps = SafeCast.toUint16(vm.envUint("COVEN_PLATFORM_FEE_BPS"));
        address[] memory hooks = _hooks();
        ICovenRouter.TemplateInit[] memory templates = _templates();
        require(block.chainid == 5042, "not arc mainnet");
        require(owner.code.length != 0, "owner must be a contract wallet");
        require(feeRecipient != owner, "fee recipient must differ from owner");
        for (uint256 i; i < hooks.length; ++i) {
            require(hooks[i].code.length != 0, "allowed hook has no code");
        }
        for (uint256 i; i < templates.length; ++i) {
            require(templates[i].referenceHook.code.length != 0, "template hook has no code");
        }
        vm.startBroadcast();
        router = new CovenRouter(owner, feeRecipient, guardian, platformFeeBps, hooks, templates);
        lens = new CovenLens(router);
        vm.stopBroadcast();
        require(router.owner() == owner && router.platformFeeBps() == platformFeeBps, "router misconfigured");
        require(address(lens.router()) == address(router), "lens misconfigured");
        require(router.hookTemplateIds().length == templates.length, "templates not registered");
        for (uint256 i; i < hooks.length; ++i) {
            require(router.isHookAllowed(hooks[i]), "hook not allowed");
        }
        for (uint256 i; i < templates.length; ++i) {
            require(router.isHookAllowed(templates[i].referenceHook), "template hook not matched");
        }
        console.log("CovenRouter", address(router));
        console.log("CovenLens", address(lens));
        console.log("allowedHooks", hooks.length);
        console.log("hookTemplates", templates.length);
    }

    function _hooks() internal view returns (address[] memory hooks) {
        hooks = vm.envOr("COVEN_INITIAL_HOOKS", ",", new address[](0));
    }

    function _templates() internal view returns (ICovenRouter.TemplateInit[] memory templates) {
        bytes memory blob = vm.envOr("COVEN_INITIAL_TEMPLATES", bytes(""));
        if (blob.length == 0) return new ICovenRouter.TemplateInit[](0);
        templates = abi.decode(blob, (ICovenRouter.TemplateInit[]));
    }
}
