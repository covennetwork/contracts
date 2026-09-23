// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// Gas benchmark for CovenLens._simulate. Backs finding H-03: the price-impact cap
// bounds the *price range* a quote walks, not the number of initialised ticks inside
// it, and tick density is attacker-controlled.

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CovenLens} from "../../src/CovenLens.sol";
import {ICovenRouter} from "../../src/interfaces/ICovenRouter.sol";

/// Every tick initialised, zero net liquidity change: the cheapest possible
/// per-tick cost, so the numbers below are a lower bound.
contract DenseV3Pool {
    uint160 public immutable startSqrtP;

    constructor(uint160 sqrtP) {
        startSqrtP = sqrtP;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (startSqrtP, 0, 0, 0, 0, 0, true);
    }

    function liquidity() external pure returns (uint128) {
        return 1e24;
    }

    function tickBitmap(int16) external pure returns (uint256) {
        return type(uint256).max;
    }

    function ticks(int24) external pure returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool) {
        return (1e24, 0, 0, 0, 0, 0, 0, true);
    }
}

contract DenseV3Factory {
    address public pool;
    uint256 public tiers = 1; // how many of the four fee tiers the attacker has seeded

    function set(address p, uint256 t) external {
        pool = p;
        tiers = t;
    }

    function getPool(address, address, uint24 fee) external view returns (address) {
        if (fee == 100) return pool;
        if (fee == 500 && tiers > 1) return pool;
        if (fee == 3000 && tiers > 2) return pool;
        if (fee == 10_000 && tiers > 3) return pool;
        return address(0);
    }
}

/// PoolManager stub: extsload returns zero, so every v4 candidate bails on sqrtP == 0.
contract NullPoolManager {
    function extsload(bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }

    function extsload(bytes32, uint256 n) external pure returns (bytes32[] memory r) {
        r = new bytes32[](n);
    }
}

contract LensGasBench is Test {
    address constant V3_FACTORY = 0xf0db7b58379503491d857dB50AC9ece64c653918;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    CovenLens lens;
    address tokenIn = address(uint160(0x1111));
    address tokenOut = address(uint160(0x2222));

    function setUp() public {
        deployCodeTo("LensGasBench.t.sol:DenseV3Factory", "", V3_FACTORY);
        deployCodeTo("LensGasBench.t.sol:NullPoolManager", "", POOL_MANAGER);
        DenseV3Pool pool = new DenseV3Pool(79228162514264337593543950336); // 1:1
        DenseV3Factory(V3_FACTORY).set(address(pool), 1);
        lens = new CovenLens(ICovenRouter(address(0)));
    }

    function _quote(uint16 impactBps, address[] memory connectors) internal returns (uint256 gasUsed) {
        uint256 g = gasleft();
        lens.quote(tokenIn, tokenOut, 1e30, connectors, new PoolKey[](0), impactBps);
        gasUsed = g - gasleft();
    }

    function _warm() internal {
        _quote(10, new address[](0));
    }

    /// One seeded tier, direct leg only. Cost tracks the tick span the impact cap admits.
    function test_H03_costScalesWithTheImpactCap() public {
        address[] memory none = new address[](0);
        _warm();
        emit log_named_uint("1 tier, direct leg, impact  100bps (~101 ticks)", _quote(100, none));
        emit log_named_uint("1 tier, direct leg, impact  500bps (~513 ticks)", _quote(500, none));
        uint256 wide = _quote(1000, none);
        emit log_named_uint("1 tier, direct leg, impact 1000bps (budget-capped)", wide);
        assertLt(wide, 4_000_000, "a single leg cannot exceed the step budget");
    }

    /// Cost is concentrated in the 0.01% tier, the only one with tickSpacing == 1.
    /// Seeding the coarser tiers adds little, because their spacing strides over the
    /// same price range in 10/60/200-tick jumps. An attacker seeds the 1-spacing pool.
    function test_H03_costIsConcentratedInTheSpacing1Tier() public {
        _warm();
        address[] memory two = new address[](2);
        two[0] = address(uint160(0x3333));
        two[1] = address(uint160(0x4444));

        DenseV3Pool pool = DenseV3Pool(DenseV3Factory(V3_FACTORY).pool());
        uint256[4] memory used;
        for (uint256 t = 1; t <= 4; ++t) {
            DenseV3Factory(V3_FACTORY).set(address(pool), t);
            used[t - 1] = _quote(500, two);
        }
        emit log_named_uint("quote, 2 connectors, spacing-1 tier only     ", used[0]);
        emit log_named_uint("quote, 2 connectors, + spacing-10 tier       ", used[1]);
        emit log_named_uint("quote, 2 connectors, + spacing-60 tier       ", used[2]);
        emit log_named_uint("quote, 2 connectors, + spacing-200 tier      ", used[3]);

        // H-03 regression: MAX_SWAP_STEPS is a hard ceiling on tick-crossing work for the
        // whole call, so seeding more pools can no longer push the quote past it.
        assertLt(used[3], 5_000_000, "total work stays bounded however many pools are seeded");
        assertLt(used[3] - used[0], used[0] / 2, "extra seeded tiers cannot escalate the cost");
    }
}
