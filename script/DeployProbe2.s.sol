// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CovenProbe2} from "../src/CovenProbe2.sol";

/// Deploys CovenProbe2 on a chain whose gas token has a wrapped ERC-20.
///   COVEN_PROBE_OWNER=0x… COVEN_PROBE_FEE_RECIPIENT=0x… forge script script/DeployProbe2.s.sol \
///     --rpc-url robinhood --broadcast --private-key …
contract DeployProbe2 is Script {
    uint16 internal constant DEFAULT_FEE_BPS = 1000;
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    // Robinhood Chain WETH (Arbitrum's bridged WETH: deposit/withdraw).
    address internal constant ROBINHOOD_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    function run() external returns (CovenProbe2 probe) {
        address owner = vm.envAddress("COVEN_PROBE_OWNER");
        address feeRecipient = vm.envAddress("COVEN_PROBE_FEE_RECIPIENT");
        uint16 feeBps = SafeCast.toUint16(vm.envOr("COVEN_PROBE_FEE_BPS", uint256(DEFAULT_FEE_BPS)));
        require(block.chainid == 4663, "not Robinhood Chain");
        require(feeBps != 0, "fee must be non-zero");
        require(address(POOL_MANAGER).code.length != 0, "no PoolManager");
        vm.startBroadcast();
        probe = new CovenProbe2(owner, feeRecipient, feeBps, POOL_MANAGER, ROBINHOOD_WETH);
        vm.stopBroadcast();
        require(probe.owner() == owner, "owner mismatch");
        require(probe.feeBps() == feeBps, "fee mismatch");
        require(probe.feeRecipient() == feeRecipient, "fee recipient mismatch");
        console.log("CovenProbe2", address(probe));
        console.log("feeBps", feeBps);
    }
}
