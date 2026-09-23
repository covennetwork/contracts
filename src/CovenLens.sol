// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ICovenRouter} from "./interfaces/ICovenRouter.sol";
import {IUniswapV3Factory, IUniswapV3Pool} from "./interfaces/external/IUniswapV3.sol";
import {IV4Quoter} from "./interfaces/external/IV4Quoter.sol";
contract CovenLens {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using ProtocolFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint16;
    using LPFeeLibrary for uint24;
    struct Pool {
        ICovenRouter.Protocol protocol;
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        address pool;
        bytes32 poolId;
        uint128 liquidity;
        uint160 sqrtPriceX96;
    }
    struct PoolRef {
        bool isV4;
        address pool;
        PoolId id;
        int24 tickSpacing;
        uint24 fee;
    }
    IUniswapV3Factory public constant V3_FACTORY = IUniswapV3Factory(0xf0db7b58379503491d857dB50AC9ece64c653918);
    IPoolManager public constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IV4Quoter public constant V4_QUOTER = IV4Quoter(0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94);
    uint256 public constant HOOKED_QUOTE_GAS = 2_000_000;
    uint256 public constant MAX_SWAP_STEPS = 512;
    uint256 private constant BPS = 10_000;
    uint256 private constant Q96 = 1 << 96;
    uint256 private constant TIER_COUNT = 4;
    uint160 private constant SWAP_HOOK_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    ICovenRouter public immutable router;
    error InvalidImpact();
    constructor(ICovenRouter covenRouter) {
        router = covenRouter;
    }
    function quote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address[] calldata connectors,
        PoolKey[] calldata extraPools,
        uint16 maxImpactBps
    ) external returns (ICovenRouter.Hop[] memory hops, uint256 amountOut) {
        if (maxImpactBps == 0 || maxImpactBps >= BPS) revert InvalidImpact();
        if (tokenIn == tokenOut || tokenIn == address(0) || tokenOut == address(0) || amountIn == 0) {
            return (hops, 0);
        }
        uint256[1] memory budget;
        budget[0] = MAX_SWAP_STEPS;
        (ICovenRouter.Hop memory direct, uint256 directOut) =
            _bestLeg(tokenIn, tokenOut, amountIn, extraPools, maxImpactBps, budget);
        if (directOut != 0) {
            hops = new ICovenRouter.Hop[](1);
            hops[0] = direct;
            amountOut = directOut;
        }
        for (uint256 i; i < connectors.length; ++i) {
            address mid = connectors[i];
            if (mid == tokenIn || mid == tokenOut || mid == address(0)) continue;
            (ICovenRouter.Hop memory first, uint256 midAmount) =
                _bestLeg(tokenIn, mid, amountIn, extraPools, maxImpactBps, budget);
            if (midAmount == 0) continue;
            (ICovenRouter.Hop memory second, uint256 out) =
                _bestLeg(mid, tokenOut, midAmount, extraPools, maxImpactBps, budget);
            if (out > amountOut) {
                hops = new ICovenRouter.Hop[](2);
                hops[0] = first;
                hops[1] = second;
                amountOut = out;
            }
        }
    }
    function discoverPools(address[] calldata tokens) external view returns (Pool[] memory pools) {
        uint256 n = tokens.length;
        if (n < 2) return pools;
        Pool[] memory found = new Pool[](n * (n - 1) * TIER_COUNT);
        uint256 count;
        for (uint256 i; i < n; ++i) {
            for (uint256 j = i + 1; j < n; ++j) {
                if (tokens[i] == tokens[j]) continue;
                (address token0, address token1) = tokens[i] < tokens[j] ? (tokens[i], tokens[j]) : (tokens[j], tokens[i]);
                for (uint256 t; t < TIER_COUNT; ++t) {
                    (uint24 fee, int24 spacing) = _tier(t);
                    address v3Pool = V3_FACTORY.getPool(token0, token1, fee);
                    if (v3Pool != address(0)) {
                        (uint160 sqrtP,,,,,,) = IUniswapV3Pool(v3Pool).slot0();
                        found[count++] = Pool({
                            protocol: ICovenRouter.Protocol.V3,
                            token0: token0,
                            token1: token1,
                            fee: fee,
                            tickSpacing: spacing,
                            hooks: address(0),
                            pool: v3Pool,
                            poolId: bytes32(0),
                            liquidity: IUniswapV3Pool(v3Pool).liquidity(),
                            sqrtPriceX96: sqrtP
                        });
                    }
                    PoolId id = _key(token0, token1, fee, spacing, address(0)).toId();
                    (uint160 sqrtP4,,,) = POOL_MANAGER.getSlot0(id);
                    if (sqrtP4 != 0) {
                        found[count++] = Pool({
                            protocol: ICovenRouter.Protocol.V4,
                            token0: token0,
                            token1: token1,
                            fee: fee,
                            tickSpacing: spacing,
                            hooks: address(0),
                            pool: address(POOL_MANAGER),
                            poolId: PoolId.unwrap(id),
                            liquidity: POOL_MANAGER.getLiquidity(id),
                            sqrtPriceX96: sqrtP4
                        });
                    }
                }
            }
        }
        pools = new Pool[](count);
        for (uint256 k; k < count; ++k) {
            pools[k] = found[k];
        }
    }
    function _bestLeg(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        PoolKey[] calldata extraPools,
        uint16 maxImpactBps,
        uint256[1] memory budget
    ) private returns (ICovenRouter.Hop memory best, uint256 bestOut) {
        bool zeroForOne = tokenIn < tokenOut;
        (address token0, address token1) = zeroForOne ? (tokenIn, tokenOut) : (tokenOut, tokenIn);
        for (uint256 t; t < TIER_COUNT; ++t) {
            (uint24 fee, int24 spacing) = _tier(t);
            address v3Pool = V3_FACTORY.getPool(token0, token1, fee);
            if (v3Pool != address(0)) {
                uint256 out = _simulate(
                    PoolRef({isV4: false, pool: v3Pool, id: PoolId.wrap(0), tickSpacing: spacing, fee: fee}),
                    zeroForOne,
                    amountIn,
                    maxImpactBps,
                    budget
                );
                if (out > bestOut) {
                    bestOut = out;
                    best = ICovenRouter.Hop(ICovenRouter.Protocol.V3, tokenOut, fee, 0, address(0));
                }
            }
            uint256 out4 =
                _simulateV4(_key(token0, token1, fee, spacing, address(0)), zeroForOne, amountIn, maxImpactBps, budget);
            if (out4 > bestOut) {
                bestOut = out4;
                best = ICovenRouter.Hop(ICovenRouter.Protocol.V4, tokenOut, fee, spacing, address(0));
            }
        }
        for (uint256 e; e < extraPools.length; ++e) {
            PoolKey calldata key = extraPools[e];
            if (Currency.unwrap(key.currency0) != token0 || Currency.unwrap(key.currency1) != token1) continue;
            address hooks = address(key.hooks);
            bool swapPermissioned = uint160(hooks) & SWAP_HOOK_FLAGS != 0;
            bool needsAllowlist = hooks != address(0) && (swapPermissioned || key.fee.isDynamicFee());
            uint256 out;
            if (!needsAllowlist) {
                out = _simulateV4(key, zeroForOne, amountIn, maxImpactBps, budget);
            } else if (router.isHookAllowed(hooks)) {
                out = swapPermissioned
                    ? _quoteHooked(key, zeroForOne, amountIn, maxImpactBps)
                    : _simulateV4(key, zeroForOne, amountIn, maxImpactBps, budget);
            }
            if (out > bestOut) {
                bestOut = out;
                best = ICovenRouter.Hop(ICovenRouter.Protocol.V4, tokenOut, key.fee, key.tickSpacing, hooks);
            }
        }
    }
    function _simulateV4(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint16 maxImpactBps,
        uint256[1] memory budget
    ) private view returns (uint256) {
        if (key.tickSpacing < TickMath.MIN_TICK_SPACING || key.tickSpacing > TickMath.MAX_TICK_SPACING) return 0;
        PoolId id = key.toId();
        (uint160 sqrtP,, uint24 protocolFee, uint24 lpFee) = POOL_MANAGER.getSlot0(id);
        if (sqrtP == 0) return 0;
        uint16 directionalFee = zeroForOne ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee();
        uint24 swapFee = directionalFee == 0 ? lpFee : directionalFee.calculateSwapFee(lpFee);
        if (swapFee >= SwapMath.MAX_SWAP_FEE) return 0;
        return _simulate(
            PoolRef({isV4: true, pool: address(0), id: id, tickSpacing: key.tickSpacing, fee: swapFee}),
            zeroForOne,
            amountIn,
            maxImpactBps,
            budget
        );
    }
    function _quoteHooked(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint16 maxImpactBps)
        private
        returns (uint256 amountOut)
    {
        if (amountIn > type(uint128).max) return 0;
        (uint160 sqrtP,,,) = POOL_MANAGER.getSlot0(key.toId());
        if (sqrtP == 0) return 0;
        try V4_QUOTER.quoteExactInputSingle{gas: HOOKED_QUOTE_GAS}(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                exactAmount: SafeCast.toUint128(amountIn),
                hookData: ""
            })
        ) returns (uint256 out, uint256) {
            amountOut = out;
        } catch {
            return 0;
        }
        uint256 spot = zeroForOne
            ? Math.mulDiv(Math.mulDiv(amountIn, sqrtP, Q96), sqrtP, Q96)
            : Math.mulDiv(Math.mulDiv(amountIn, Q96, sqrtP), Q96, sqrtP);
        if (amountOut < Math.mulDiv(spot, BPS - maxImpactBps, BPS)) return 0;
    }
    function _simulate(
        PoolRef memory ref,
        bool zeroForOne,
        uint256 amountIn,
        uint16 maxImpactBps,
        uint256[1] memory budget
    ) private view returns (uint256 amountOut) {
        if (amountIn > uint256(type(int256).max)) return 0;
        (uint160 sqrtP, int24 tick, uint128 liquidity) = _state(ref);
        if (sqrtP == 0) return 0;
        uint160 limit = _priceLimit(sqrtP, zeroForOne, maxImpactBps);
        if (zeroForOne ? limit >= sqrtP : limit <= sqrtP) return 0;
        int256 remaining = -SafeCast.toInt256(amountIn);
        while (remaining != 0 && sqrtP != limit) {
            if (budget[0] == 0) return 0;
            --budget[0];
            uint160 start = sqrtP;
            (int24 next, bool initialized) = _nextTick(ref, tick, zeroForOne);
            uint160 sqrtNext = TickMath.getSqrtPriceAtTick(next);
            uint256 stepIn;
            uint256 stepOut;
            uint256 stepFee;
            (sqrtP, stepIn, stepOut, stepFee) = SwapMath.computeSwapStep(
                sqrtP, SwapMath.getSqrtPriceTarget(zeroForOne, sqrtNext, limit), liquidity, remaining, ref.fee
            );
            remaining += SafeCast.toInt256(stepIn + stepFee);
            amountOut += stepOut;
            if (sqrtP == sqrtNext) {
                if (initialized) {
                    int128 net = _liquidityNet(ref, next);
                    liquidity = LiquidityMath.addDelta(liquidity, zeroForOne ? -net : net);
                }
                tick = zeroForOne ? next - 1 : next;
            } else if (sqrtP != start) {
                tick = TickMath.getTickAtSqrtPrice(sqrtP);
            }
        }
        if (remaining != 0) return 0;
    }
    function _state(PoolRef memory ref) private view returns (uint160 sqrtP, int24 tick, uint128 liquidity) {
        if (ref.isV4) {
            (sqrtP, tick,,) = POOL_MANAGER.getSlot0(ref.id);
            liquidity = POOL_MANAGER.getLiquidity(ref.id);
        } else {
            (sqrtP, tick,,,,,) = IUniswapV3Pool(ref.pool).slot0();
            liquidity = IUniswapV3Pool(ref.pool).liquidity();
        }
    }
    function _nextTick(PoolRef memory ref, int24 tick, bool lte) private view returns (int24 next, bool initialized) {
        int24 spacing = ref.tickSpacing;
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        int256 target;
        if (lte) {
            (int16 wordPos, uint8 bitPos) = _position(compressed);
            uint256 masked = _word(ref, wordPos) & (type(uint256).max >> (uint256(type(uint8).max) - bitPos));
            initialized = masked != 0;
            target = initialized
                ? int256(compressed) - int256(uint256(bitPos - BitMath.mostSignificantBit(masked)))
                : int256(compressed) - int256(uint256(bitPos));
        } else {
            (int16 wordPos, uint8 bitPos) = _position(compressed + 1);
            uint256 masked = _word(ref, wordPos) & ~((uint256(1) << bitPos) - 1);
            initialized = masked != 0;
            target = initialized
                ? int256(compressed) + 1 + int256(uint256(BitMath.leastSignificantBit(masked) - bitPos))
                : int256(compressed) + 1 + int256(uint256(type(uint8).max - bitPos));
        }
        target *= spacing;
        if (target <= TickMath.MIN_TICK) return (TickMath.MIN_TICK, initialized && target == TickMath.MIN_TICK);
        if (target >= TickMath.MAX_TICK) return (TickMath.MAX_TICK, initialized && target == TickMath.MAX_TICK);
        next = SafeCast.toInt24(target);
    }
    function _position(int24 compressed) private pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = SafeCast.toInt16(int256(compressed >> 8));
        bitPos = SafeCast.toUint8(SafeCast.toUint256(int256(compressed) & 0xff));
    }
    function _word(PoolRef memory ref, int16 wordPos) private view returns (uint256) {
        return ref.isV4 ? POOL_MANAGER.getTickBitmap(ref.id, wordPos) : IUniswapV3Pool(ref.pool).tickBitmap(wordPos);
    }
    function _liquidityNet(PoolRef memory ref, int24 tick) private view returns (int128 net) {
        if (ref.isV4) {
            (, net) = POOL_MANAGER.getTickLiquidity(ref.id, tick);
        } else {
            (, net,,,,,,) = IUniswapV3Pool(ref.pool).ticks(tick);
        }
    }
    function _priceLimit(uint160 sqrtP, bool zeroForOne, uint16 maxImpactBps) private pure returns (uint160) {
        uint256 factor = Math.sqrt((zeroForOne ? BPS - maxImpactBps : BPS + maxImpactBps) * 1e32);
        uint256 limit = Math.mulDiv(sqrtP, factor, 1e18);
        if (zeroForOne) return limit <= TickMath.MIN_SQRT_PRICE ? TickMath.MIN_SQRT_PRICE + 1 : SafeCast.toUint160(limit);
        return limit >= TickMath.MAX_SQRT_PRICE ? TickMath.MAX_SQRT_PRICE - 1 : SafeCast.toUint160(limit);
    }
    function _tier(uint256 index) private pure returns (uint24 fee, int24 spacing) {
        if (index == 0) return (100, 1);
        if (index == 1) return (500, 10);
        if (index == 2) return (3000, 60);
        return (10_000, 200);
    }
    function _key(address token0, address token1, uint24 fee, int24 spacing, address hooks)
        private
        pure
        returns (PoolKey memory)
    {
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(hooks)
        });
    }
}
