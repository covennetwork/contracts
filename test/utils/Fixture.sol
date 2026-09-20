// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CovenRouter} from "../../src/CovenRouter.sol";
import {CovenLens} from "../../src/CovenLens.sol";
import {ICovenRouter} from "../../src/interfaces/ICovenRouter.sol";
import {TestToken} from "./TestToken.sol";
import {LiquidityProvider} from "./LiquidityProvider.sol";
import {OutputFeeHook, GreedyHook} from "./TestHooks.sol";
interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }
    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96)
        external
        payable
        returns (address pool);
    function mint(MintParams calldata params) external payable returns (uint256, uint128, uint256, uint256);
}
interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }
    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}
abstract contract Fixture is Test {
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    address internal constant EURC = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    INonfungiblePositionManager internal constant NPM =
        INonfungiblePositionManager(0x39654A85A4C05127f5Fd6ED22CAeC077A0fB1377);
    IQuoterV2 internal constant QUOTER_V2 = IQuoterV2(0x7DfD4F31be6814D2906BDE155c3e1B146EAc1468);
    address internal constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    uint16 internal constant PLATFORM_FEE_BPS = 30;
    uint16 internal constant IMPACT_BPS = 500;
    CovenRouter internal router;
    CovenLens internal lens;
    TestToken internal tokenA;
    TestToken internal tokenB;
    TestToken internal tokenC;
    TestToken internal tokenD;
    TestToken internal tokenE;
    TestToken internal tokenF;
    OutputFeeHook internal hookOne;
    OutputFeeHook internal hookTwo;
    GreedyHook internal greedyHook;
    PoolKey internal hookedKeyC;
    PoolKey internal hookedKeyE;
    PoolKey internal greedyKeyF;
    LiquidityProvider internal provider;
    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal guardian = makeAddr("guardian");
    address internal partner = makeAddr("partner");
    address internal user = makeAddr("user");
    function setUp() public virtual {
        vm.createSelectFork("arc");
        router = new CovenRouter(owner, treasury, guardian, PLATFORM_FEE_BPS);
        lens = new CovenLens(router);
        provider = new LiquidityProvider(POOL_MANAGER);
        vm.deal(address(this), 100_000_000e18);
        vm.deal(address(provider), 100_000_000e18);
        IERC20(USDC).approve(address(NPM), type(uint256).max);
        tokenA = _token("A");
        tokenB = _token("B");
        tokenC = _token("C");
        tokenD = _token("D");
        tokenE = _token("E");
        tokenF = _token("F");
        _v3FullRange(address(tokenA), 3000, 1_000_000e18, 1_000_000e6);
        _v3Narrow(address(tokenD), 10_000, 100e18, 100e6);
        _v4FullRange(_poolKey(address(tokenB), 500, 10, address(0)), 1e18);
        hookOne = OutputFeeHook(_deployHook("TestHooks.sol:OutputFeeHook", abi.encode(POOL_MANAGER, 100), 0xC0FFEE));
        hookTwo = OutputFeeHook(_deployHook("TestHooks.sol:OutputFeeHook", abi.encode(POOL_MANAGER, 200), 0xBEEF));
        greedyHook = GreedyHook(_deployHook("TestHooks.sol:GreedyHook", abi.encode(POOL_MANAGER), 0xBAD));
        hookedKeyC = _poolKey(address(tokenC), 10_000, 200, address(hookOne));
        hookedKeyE = _poolKey(address(tokenE), 10_000, 200, address(hookTwo));
        greedyKeyF = _poolKey(address(tokenF), 10_000, 200, address(greedyHook));
        _v4FullRange(hookedKeyC, 1e18);
        _v4FullRange(hookedKeyE, 1e18);
        _v4FullRange(greedyKeyF, 1e18);
        vm.deal(user, 10_000_000e18);
        vm.startPrank(user);
        IERC20(USDC).approve(address(router), type(uint256).max);
        TestToken[6] memory all = [tokenA, tokenB, tokenC, tokenD, tokenE, tokenF];
        for (uint256 i; i < all.length; ++i) {
            all[i].approve(address(router), type(uint256).max);
        }
        vm.stopPrank();
    }
    function _token(string memory symbol) internal returns (TestToken token) {
        token = new TestToken(symbol);
        token.mint(address(this), 100_000_000e18);
        token.mint(address(provider), 100_000_000e18);
        token.mint(user, 10_000_000e18);
        token.approve(address(NPM), type(uint256).max);
    }
    function _sorted(address token) internal pure returns (address token0, address token1) {
        return token < USDC ? (token, USDC) : (USDC, token);
    }
    function _sqrtPrice(address token, uint256 tokenAmount, uint256 usdcAmount) internal pure returns (uint160) {
        uint256 ratio = token < USDC
            ? Math.mulDiv(usdcAmount, 1 << 192, tokenAmount)
            : Math.mulDiv(tokenAmount, 1 << 192, usdcAmount);
        return SafeCast.toUint160(Math.sqrt(ratio));
    }
    function _v3FullRange(address token, uint24 fee, uint256 tokenAmount, uint256 usdcAmount) internal {
        (address token0, address token1) = _sorted(token);
        NPM.createAndInitializePoolIfNecessary(token0, token1, fee, _sqrtPrice(token, tokenAmount, usdcAmount));
        int24 spacing = fee == 500 ? int24(10) : fee == 3000 ? int24(60) : int24(200);
        (uint256 amount0, uint256 amount1) = token < USDC ? (tokenAmount, usdcAmount) : (usdcAmount, tokenAmount);
        NPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: fee,
                tickLower: TickMath.minUsableTick(spacing),
                tickUpper: TickMath.maxUsableTick(spacing),
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
    }
    function _v3Narrow(address token, uint24 fee, uint256 tokenAmount, uint256 usdcAmount) internal {
        (address token0, address token1) = _sorted(token);
        uint160 sqrtP = _sqrtPrice(token, tokenAmount, usdcAmount);
        NPM.createAndInitializePoolIfNecessary(token0, token1, fee, sqrtP);
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 base = tick / 200 * 200;
        (uint256 amount0, uint256 amount1) = token < USDC ? (tokenAmount, usdcAmount) : (usdcAmount, tokenAmount);
        NPM.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: fee,
                tickLower: base - 400,
                tickUpper: base + 400,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
    }
    function _poolKey(address token, uint24 fee, int24 spacing, address hooks) internal pure returns (PoolKey memory) {
        (address token0, address token1) = _sorted(token);
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(hooks)
        });
    }
    function _v4FullRange(PoolKey memory key, uint256 liquidity) internal {
        address token = Currency.unwrap(key.currency0) == USDC ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        POOL_MANAGER.initialize(key, _sqrtPrice(token, 1e18, 1e6));
        provider.addLiquidity(
            key, TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), liquidity
        );
    }
    function _deployHook(string memory artifact, bytes memory args, uint160 prefix) internal returns (address hook) {
        uint160 flags = uint160((1 << 6) | (1 << 2));
        hook = address((prefix << 140) | flags);
        deployCodeTo(artifact, args, hook);
    }
    function _v3(address tokenOut, uint24 fee) internal pure returns (ICovenRouter.Hop memory) {
        return ICovenRouter.Hop(ICovenRouter.Protocol.V3, tokenOut, fee, 0, address(0));
    }
    function _v4(address tokenOut, uint24 fee, int24 spacing, address hooks)
        internal
        pure
        returns (ICovenRouter.Hop memory)
    {
        return ICovenRouter.Hop(ICovenRouter.Protocol.V4, tokenOut, fee, spacing, hooks);
    }
    function _one(ICovenRouter.Hop memory hop) internal pure returns (ICovenRouter.Hop[] memory hops) {
        hops = new ICovenRouter.Hop[](1);
        hops[0] = hop;
    }
    function _two(ICovenRouter.Hop memory first, ICovenRouter.Hop memory second)
        internal
        pure
        returns (ICovenRouter.Hop[] memory hops)
    {
        hops = new ICovenRouter.Hop[](2);
        hops[0] = first;
        hops[1] = second;
    }
    function _params(address tokenIn, uint256 amountIn, ICovenRouter.Hop[] memory hops, uint256 minOut)
        internal
        view
        returns (ICovenRouter.SwapParams memory)
    {
        return ICovenRouter.SwapParams({
            tokenIn: tokenIn,
            amountIn: amountIn,
            hops: hops,
            minAmountOut: minOut,
            deadline: block.timestamp,
            integrator: address(0),
            integratorFeeBps: 0
        });
    }
    function _connectors() internal pure returns (address[] memory connectors) {
        connectors = new address[](2);
        connectors[0] = USDC;
        connectors[1] = EURC;
    }
    function _extras() internal view returns (PoolKey[] memory keys) {
        keys = new PoolKey[](3);
        keys[0] = hookedKeyC;
        keys[1] = hookedKeyE;
        keys[2] = greedyKeyF;
    }
    function _quote(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (ICovenRouter.Hop[] memory hops, uint256 amountOut)
    {
        return lens.quote(tokenIn, tokenOut, amountIn, _connectors(), _extras(), IMPACT_BPS);
    }
    function _fee(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return amount * bps / 10_000;
    }
    function _assertRouterEmpty() internal view {
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "router usdc");
        TestToken[6] memory all = [tokenA, tokenB, tokenC, tokenD, tokenE, tokenF];
        for (uint256 i; i < all.length; ++i) {
            assertEq(all[i].balanceOf(address(router)), 0, "router token");
        }
    }
    function _allowTemplateFrom(address referenceHook, address otherHook) internal returns (bytes32 id) {
        bytes memory a = referenceHook.code;
        bytes memory b = otherHook.code;
        assertEq(a.length, b.length, "template size");
        uint16[] memory offsets = new uint16[](8);
        uint256 count;
        uint256 pc;
        while (pc < a.length) {
            uint8 op = uint8(a[pc]);
            if (op >= 0x60 && op <= 0x7f) {
                uint256 size = op - 0x5f;
                if (size == 32 && keccak256(_slice(a, pc + 1, 32)) != keccak256(_slice(b, pc + 1, 32))) {
                    offsets[count++] = SafeCast.toUint16(pc + 1);
                }
                pc += 1 + size;
            } else {
                pc += 1;
            }
        }
        assertGt(count, 0, "no immutable differences");
        uint16[] memory trimmed = new uint16[](count);
        for (uint256 i; i < count; ++i) {
            trimmed[i] = offsets[i];
        }
        vm.prank(owner);
        id = router.addHookTemplate(referenceHook, trimmed);
    }
    function _slice(bytes memory data, uint256 start, uint256 length) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i; i < length; ++i) {
            out[i] = data[start + i];
        }
    }
}
