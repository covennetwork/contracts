// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Fixture, IQuoterV2} from "./utils/Fixture.sol";
import {CovenLens} from "../src/CovenLens.sol";
import {ICovenRouter} from "../src/interfaces/ICovenRouter.sol";
import {IV4Quoter} from "../src/interfaces/external/IV4Quoter.sol";
contract CovenLensTest is Fixture {
    IV4Quoter internal constant V4_QUOTER = IV4Quoter(0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94);
    function testFuzz_v3MatchesQuoterV2(uint256 amountIn, bool buy) public {
        amountIn = buy ? bound(amountIn, 1, 200_000e6) : bound(amountIn, 1e6, 200_000e18);
        (address tokenIn, address tokenOut) = buy ? (USDC, address(tokenA)) : (address(tokenA), USDC);
        (ICovenRouter.Hop[] memory hops, uint256 out) =
            lens.quote(tokenIn, tokenOut, amountIn, new address[](0), new PoolKey[](0), 9_999);
        (uint256 expected,,,) = QUOTER_V2.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams(tokenIn, tokenOut, amountIn, 3000, 0)
        );
        assertEq(out, expected);
        if (expected != 0) assertEq(hops[0].fee, 3000);
    }
    function testFuzz_v4HooklessMatchesV4Quoter(uint256 amountIn, bool buy) public {
        amountIn = buy ? bound(amountIn, 1, 200_000e6) : bound(amountIn, 1e6, 200_000e18);
        (address tokenIn, address tokenOut) = buy ? (USDC, address(tokenB)) : (address(tokenB), USDC);
        (ICovenRouter.Hop[] memory hops, uint256 out) =
            lens.quote(tokenIn, tokenOut, amountIn, new address[](0), new PoolKey[](0), 9_999);
        PoolKey memory key = _poolKey(address(tokenB), 500, 10, address(0));
        (uint256 expected,) = V4_QUOTER.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams(key, tokenIn < tokenOut, SafeCast.toUint128(amountIn), "")
        );
        assertEq(out, expected);
        if (expected != 0) assertEq(uint8(hops[0].protocol), uint8(ICovenRouter.Protocol.V4));
    }
    function test_hookedQuoteMatchesV4QuoterOnlyWhenAllowed() public {
        (, uint256 hidden) = _quote(USDC, address(tokenC), 50e6);
        assertEq(hidden, 0);
        vm.prank(owner);
        router.setHookAllowed(address(hookOne), true);
        (ICovenRouter.Hop[] memory hops, uint256 out) = _quote(USDC, address(tokenC), 50e6);
        (uint256 expected,) = V4_QUOTER.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams(hookedKeyC, USDC < address(tokenC), 50e6, "")
        );
        assertEq(out, expected);
        assertEq(hops[0].hooks, address(hookOne));
    }
    function test_hookedQuoteRespectsImpactCap() public {
        vm.startPrank(owner);
        router.setHookAllowed(address(greedyHook), true);
        router.setHookAllowed(address(hookOne), true);
        vm.stopPrank();
        (, uint256 greedy) = _quote(USDC, address(tokenF), 50e6);
        assertEq(greedy, 0);
        (, uint256 fair) = _quote(USDC, address(tokenC), 50e6);
        assertGt(fair, 0);
    }
    function test_prefersTwoHopRouteWhenBetter() public {
        (ICovenRouter.Hop[] memory hops, uint256 out) = _quote(address(tokenA), address(tokenB), 100e18);
        assertEq(hops.length, 2);
        assertEq(hops[0].tokenOut, USDC);
        assertEq(hops[1].tokenOut, address(tokenB));
        assertGt(out, 0);
    }
    function test_impactCapSkipsDeepTradesAndBoundsGas() public {
        (, uint256 small) = _quote(USDC, address(tokenD), 1e6);
        assertGt(small, 0);
        uint256 gasBefore = gasleft();
        (ICovenRouter.Hop[] memory hops, uint256 huge) = _quote(USDC, address(tokenD), 1_000_000e6);
        assertLt(gasBefore - gasleft(), 3_000_000);
        assertEq(huge, 0);
        assertEq(hops.length, 0);
        (, uint256 loose) = lens.quote(USDC, address(tokenA), 20_000e6, _connectors(), _extras(), 500);
        (, uint256 tight) = lens.quote(USDC, address(tokenA), 20_000e6, _connectors(), _extras(), 100);
        assertGt(loose, 0);
        assertEq(tight, 0);
    }
    function test_rejectsInvalidImpact() public {
        vm.expectRevert(CovenLens.InvalidImpact.selector);
        lens.quote(USDC, address(tokenA), 1e6, _connectors(), _extras(), 0);
        vm.expectRevert(CovenLens.InvalidImpact.selector);
        lens.quote(USDC, address(tokenA), 1e6, _connectors(), _extras(), 10_000);
    }
    function test_noRouteForDegenerateInputs() public {
        (ICovenRouter.Hop[] memory hops, uint256 out) = _quote(USDC, USDC, 1e6);
        assertEq(hops.length + out, 0);
        (hops, out) = _quote(USDC, address(tokenA), 0);
        assertEq(hops.length + out, 0);
        (hops, out) = _quote(USDC, makeAddr("unknown"), 1e6);
        assertEq(hops.length + out, 0);
    }
    function test_discoverPoolsFindsV3AndV4() public view {
        address[] memory tokens = new address[](3);
        tokens[0] = USDC;
        tokens[1] = address(tokenA);
        tokens[2] = address(tokenB);
        CovenLens.Pool[] memory pools = lens.discoverPools(tokens);
        bool v3A;
        bool v4B;
        for (uint256 i; i < pools.length; ++i) {
            if (pools[i].protocol == ICovenRouter.Protocol.V3 && pools[i].fee == 3000) v3A = true;
            if (pools[i].protocol == ICovenRouter.Protocol.V4 && pools[i].fee == 500) v4B = true;
            assertGt(pools[i].sqrtPriceX96, 0);
        }
        assertTrue(v3A && v4B);
        assertEq(lens.discoverPools(new address[](1)).length, 0);
    }
}
