// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Fixture, IQuoterV2} from "./utils/Fixture.sol";
import {IV4Quoter} from "../src/interfaces/external/IV4Quoter.sol";
import {IUniswapV3Factory} from "../src/interfaces/external/IUniswapV3.sol";
import {CovenArb} from "../src/CovenArb.sol";
import {TestToken} from "./utils/TestToken.sol";
import {GreedyHook} from "./utils/TestHooks.sol";

contract Reverter {
    fallback() external payable {
        revert("no");
    }
}

contract CovenArbTest is Fixture {
    IV4Quoter internal constant V4_QUOTER = IV4Quoter(0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94);
    IUniswapV3Factory internal constant V3_FACTORY = IUniswapV3Factory(0xf0db7b58379503491d857dB50AC9ece64c653918);
    CovenArb internal arb;
    TestToken internal tokenG;
    address internal v3PoolG;
    PoolKey internal v4KeyG;
    PoolKey internal v4GreedyKeyG;
    GreedyHook internal greedyG;
    address internal arbOwner = makeAddr("arbOwner");
    address internal arbFee = makeAddr("arbFee");
    address internal runner = makeAddr("runner");

    function setUp() public override {
        super.setUp();
        arb = new CovenArb(arbOwner, arbFee, 0);
        tokenG = new TestToken("G");
        tokenG.mint(address(this), 1e30);
        tokenG.mint(address(provider), 1e30);
        tokenG.approve(address(NPM), type(uint256).max);
        _v3FullRange(address(tokenG), 3000, 1_000_000e18, 1_000_000e6);
        (address t0, address t1) = _sorted(address(tokenG));
        v3PoolG = V3_FACTORY.getPool(t0, t1, 3000);
        v4KeyG = _poolKey(address(tokenG), 3000, 60, address(0));
        POOL_MANAGER.initialize(v4KeyG, _sqrtPrice(address(tokenG), 1_000_000e18, 1_060_000e6));
        provider.addLiquidity(v4KeyG, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 1e18);
        greedyG = GreedyHook(_deployHook("TestHooks.sol:GreedyHook", abi.encode(POOL_MANAGER), 0xF00D));
        v4GreedyKeyG = _poolKey(address(tokenG), 10_000, 200, address(greedyG));
        POOL_MANAGER.initialize(v4GreedyKeyG, _sqrtPrice(address(tokenG), 1_000_000e18, 1_060_000e6));
        provider.addLiquidity(v4GreedyKeyG, TickMath.minUsableTick(200), TickMath.maxUsableTick(200), 1e18);
    }

    function _limit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _emptyKey() internal pure returns (PoolKey memory) {
        return PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(0)), fee: 0, tickSpacing: 0, hooks: IHooks(address(0))});
    }

    function _buyLegV3(uint256 amountIn) internal view returns (CovenArb.Leg memory) {
        bool z = USDC < address(tokenG);
        return CovenArb.Leg({isV4: false, pool: v3PoolG, key: _emptyKey(), zeroForOne: z, amountIn: amountIn, sqrtLimit: _limit(z), fee: 3000, hookData: ""});
    }

    function _sellLegV4(PoolKey memory key, uint160 limit) internal view returns (CovenArb.Leg memory) {
        bool z = address(tokenG) < USDC;
        return CovenArb.Leg({isV4: true, pool: address(0), key: key, zeroForOne: z, amountIn: 0, sqrtLimit: limit, fee: key.fee, hookData: ""});
    }

    function _plan(CovenArb.Leg memory a, CovenArb.Leg memory b, uint256 minProfit) internal pure returns (CovenArb.Plan memory p) {
        CovenArb.Leg[] memory legs = new CovenArb.Leg[](2);
        legs[0] = a;
        legs[1] = b;
        p = CovenArb.Plan({legs: legs, profitToken: address(0), minProfit: minProfit, maxFeeBps: 2000});
        p.profitToken = 0x3600000000000000000000000000000000000000;
    }

    function _simulate(uint256 amountIn) internal returns (uint256 expectedProfit) {
        (uint256 gOut,,,) = QUOTER_V2.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({tokenIn: USDC, tokenOut: address(tokenG), amountIn: amountIn, fee: 3000, sqrtPriceLimitX96: 0})
        );
        (uint256 usdcOut,) = V4_QUOTER.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({poolKey: v4KeyG, zeroForOne: address(tokenG) < USDC, exactAmount: SafeCast.toUint128(gOut), hookData: ""})
        );
        expectedProfit = usdcOut - amountIn;
    }

    function test_forgedV3CallbackReverts() public {
        bytes memory data = abi.encode(USDC, address(tokenG), uint24(3000));
        vm.expectRevert(CovenArb.UnexpectedCallback.selector);
        arb.uniswapV3SwapCallback(1e6, 0, data);
    }

    function test_forgedV3CallbackFromEoaWithRealPoolDataReverts() public {
        bytes memory data = abi.encode(USDC, address(tokenG), uint24(3000));
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(CovenArb.UnexpectedCallback.selector);
        arb.uniswapV3SwapCallback(1e6, 0, data);
    }

    function test_twoLegV3ToV4RealizedEqualsSimulated() public {
        uint256 amountIn = 1_000e6;
        uint256 expectedProfit = _simulate(amountIn);
        assertGt(expectedProfit, 0, "no opportunity");
        CovenArb.Plan memory plan = _plan(_buyLegV3(amountIn), _sellLegV4(v4KeyG, _limit(address(tokenG) < USDC)), 1);
        uint256 before = IERC20(USDC).balanceOf(runner);
        vm.prank(runner);
        uint256 profit = arb.execute(plan);
        assertEq(profit, expectedProfit, "realized != simulated");
        assertEq(IERC20(USDC).balanceOf(runner) - before, expectedProfit, "runner payout");
        assertEq(IERC20(USDC).balanceOf(address(arb)), 0, "arb holds usdc");
        assertEq(tokenG.balanceOf(address(arb)), 0, "arb holds tokenG");
        assertEq(POOL_MANAGER.balanceOf(address(arb), uint256(uint160(USDC))), 0, "arb 6909");
    }

    function test_belowMinProfitRevertsWithNothingTaken() public {
        uint256 amountIn = 1_000e6;
        uint256 expectedProfit = _simulate(amountIn);
        CovenArb.Plan memory plan = _plan(_buyLegV3(amountIn), _sellLegV4(v4KeyG, _limit(address(tokenG) < USDC)), expectedProfit + 1e6);
        vm.prank(runner);
        vm.expectRevert(abi.encodeWithSelector(CovenArb.BelowMinProfit.selector, expectedProfit, expectedProfit + 1e6));
        arb.execute(plan);
        assertEq(IERC20(USDC).balanceOf(runner), 0, "runner got funds");
        assertEq(IERC20(USDC).balanceOf(address(arb)), 0, "arb holds usdc");
        assertEq(tokenG.balanceOf(address(arb)), 0, "arb holds tokenG");
    }

    function test_hostileHookLegRevertsAndDrainsNothing() public {
        uint256 amountIn = 1_000e6;
        CovenArb.Plan memory plan = _plan(_buyLegV3(amountIn), _sellLegV4(v4GreedyKeyG, _limit(address(tokenG) < USDC)), 1);
        vm.prank(runner);
        vm.expectRevert();
        arb.execute(plan);
        assertEq(IERC20(USDC).balanceOf(runner), 0, "runner got funds");
        assertEq(IERC20(USDC).balanceOf(address(arb)), 0, "arb holds usdc");
        assertEq(tokenG.balanceOf(address(arb)), 0, "arb holds tokenG");
    }

    function test_tightSqrtLimitBoundsLeg() public {
        uint256 amountIn = 1_000e6;
        uint256 expectedProfit = _simulate(amountIn);
        bool z = USDC < address(tokenG);
        (uint160 sqrtP,,,,,,) = _v3Slot0(v3PoolG);
        uint160 tight = z ? sqrtP - sqrtP / 100000 : sqrtP + sqrtP / 100000;
        CovenArb.Leg memory buy = _buyLegV3(amountIn);
        buy.sqrtLimit = tight;
        CovenArb.Plan memory plan = _plan(buy, _sellLegV4(v4KeyG, _limit(address(tokenG) < USDC)), expectedProfit);
        vm.prank(runner);
        vm.expectRevert();
        arb.execute(plan);
        assertEq(IERC20(USDC).balanceOf(address(arb)), 0, "arb holds usdc");
    }

    function test_feeAccruesAsErc6909ClaimAndRevertingRecipientCannotBlock() public {
        Reverter reverter = new Reverter();
        CovenArb feeArb = new CovenArb(arbOwner, address(reverter), 100);
        uint256 amountIn = 1_000e6;
        uint256 expectedProfit = _simulate(amountIn);
        uint256 expectedFee = expectedProfit * 100 / 10_000;
        CovenArb.Plan memory plan = _plan(_buyLegV3(amountIn), _sellLegV4(v4KeyG, _limit(address(tokenG) < USDC)), 1);
        uint256 before = IERC20(USDC).balanceOf(runner);
        vm.prank(runner);
        uint256 profit = feeArb.execute(plan);
        assertEq(profit, expectedProfit - expectedFee, "execute returns net");
        assertEq(IERC20(USDC).balanceOf(runner) - before, expectedProfit - expectedFee, "runner net");
        assertEq(POOL_MANAGER.balanceOf(address(reverter), uint256(uint160(USDC))), expectedFee, "6909 fee claim");
        assertEq(IERC20(USDC).balanceOf(address(feeArb)), 0, "arb holds usdc");
    }

    function test_minProfitIsCheckedNetOfFee() public {
        CovenArb feeArb = new CovenArb(arbOwner, arbFee, 1000);
        uint256 amountIn = 1_000e6;
        uint256 expectedProfit = _simulate(amountIn);
        uint256 fee = expectedProfit * 1000 / 10_000;
        uint256 net = expectedProfit - fee;
        uint256 minProfit = net + 1;
        CovenArb.Plan memory plan = _plan(_buyLegV3(amountIn), _sellLegV4(v4KeyG, _limit(address(tokenG) < USDC)), minProfit);
        vm.prank(runner);
        vm.expectRevert(abi.encodeWithSelector(CovenArb.BelowMinProfit.selector, net, minProfit));
        feeArb.execute(plan);
        assertEq(IERC20(USDC).balanceOf(runner), 0, "nothing taken");
    }

    function _v3Slot0(address pool)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16 a, uint16 b, uint16 c, uint8 d, bool e)
    {
        return IV3Slot0(pool).slot0();
    }
}

interface IV3Slot0 {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}
