// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {Test} from "forge-std/Test.sol";
import {CovenProbe} from "../src/CovenProbe.sol";
/// @notice Replays last week's wins on real Arc pools: forks at the block before each win and
/// runs the probe call that targets the winner's route, then logs what we would have taken.
/// Cases come from arb/research/replay-cases.mjs. Skipped unless REPLAY_CASES is set:
///   REPLAY_CASES=../arb/research/data/week2/replay-cases.json REPLAY_FROM=0 arc-forge test \
///     --network arc --match-contract CovenProbeReplay -vv
/// REPLAY_FROM picks the case; REPLAY_COUNT (default 1) runs more in one process, but state
/// carries between forks inside one test, so only one case per run gives exact numbers.
contract CovenProbeReplayTest is Test {
    function test_replay() public {
        string memory path = vm.envOr("REPLAY_CASES", string(""));
        if (bytes(path).length == 0) vm.skip(true);
        string memory json = vm.readFile(path);
        uint256[] memory blocks = vm.parseJsonUintArray(json, ".blocks");
        uint256 from = vm.envOr("REPLAY_FROM", uint256(0));
        uint256 to = from + vm.envOr("REPLAY_COUNT", uint256(1));
        if (to > blocks.length) to = blocks.length;
        emit log("case,route,hash,block,venues,winner_usd6,ours_usd6,gas,ok");
        for (uint256 i = from; i < to; ++i) {
            string memory c = string.concat("$.cases[", vm.toString(i), "]");
            vm.createSelectFork("arc", blocks[i] - 1);
            CovenProbe probe = new CovenProbe(address(this), address(0xBEEF), 1000);
            bytes memory data = vm.parseJsonBytes(json, string.concat(c, ".data"));
            uint256 g0 = gasleft();
            (bool ok, bytes memory ret) = address(probe).call(data);
            uint256 used = g0 - gasleft();
            uint256 ours = ok ? abi.decode(ret, (uint256[]))[0] : 0;
            emit log(
                string.concat(
                    vm.toString(i), ",",
                    vm.toString(vm.parseJsonUint(json, string.concat(c, ".route"))), ",",
                    vm.parseJsonString(json, string.concat(c, ".hash")), ",",
                    vm.toString(blocks[i]), ",",
                    vm.parseJsonString(json, string.concat(c, ".venues")), ",",
                    vm.toString(vm.parseJsonUint(json, string.concat(c, ".usd6"))), ",",
                    vm.toString(ours), ",",
                    vm.toString(used), ",",
                    ok ? "1" : "0"
                )
            );
        }
    }
}
