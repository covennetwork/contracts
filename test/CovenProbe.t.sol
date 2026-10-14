// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CovenProbe} from "../src/CovenProbe.sol";
import {TestToken} from "./utils/TestToken.sol";
import {INonfungiblePositionManager} from "./utils/Fixture.sol";
interface IV3Factory {
    function getPool(address, address, uint24) external view returns (address);
}
/// @dev Adds v4 liquidity in ERC-20s or native USDC.
contract NativeLiquidityProvider is IUnlockCallback {
    IPoolManager internal constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    receive() external payable {}
    function addLiquidity(PoolKey memory key, uint256 liquidity) external {
        PM.unlock(abi.encode(key, liquidity));
    }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint256 liquidity) = abi.decode(data, (PoolKey, uint256));
        (BalanceDelta delta,) = PM.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: SafeCast.toInt256(liquidity),
                salt: bytes32(0)
            }),
            ""
        );
        _pay(key.currency0, delta.amount0());
        _pay(key.currency1, delta.amount1());
        return "";
    }
    function _pay(Currency c, int128 amount) private {
        if (amount >= 0) return;
        uint256 owed = SafeCast.toUint256(-int256(amount));
        PM.sync(c);
        if (Currency.unwrap(c) == address(0)) {
            PM.settle{value: owed}();
        } else {
            require(IERC20(Currency.unwrap(c)).transfer(address(PM), owed), "transfer");
            PM.settle();
        }
    }
}
contract CovenProbeTest is Test {
    IPoolManager internal constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    INonfungiblePositionManager internal constant NPM = INonfungiblePositionManager(0x39654A85A4C05127f5Fd6ED22CAeC077A0fB1377);
    IV3Factory internal constant V3_FACTORY = IV3Factory(0xf0db7b58379503491d857dB50AC9ece64c653918);
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    uint256 internal constant FORK_BLOCK = 25_769_000;
    CovenProbe internal probe;
    NativeLiquidityProvider internal provider;
    TestToken internal g;
    address internal v3Pool;
    PoolKey internal v4Key;
    address internal owner = makeAddr("owner");
    address internal feeTo = makeAddr("feeTo");
    // Anyone can call; the caller is paid.
    address internal executor = makeAddr("caller");
    function setUp() public {
        vm.createSelectFork("arc", FORK_BLOCK);
        probe = new CovenProbe(owner, feeTo, 1000);
        provider = new NativeLiquidityProvider();
        vm.deal(address(this), 100_000_000e18);
        vm.deal(address(provider), 100_000_000e18);
        g = new TestToken("G");
        g.mint(address(this), 1e30);
        g.mint(address(provider), 1e30);
        g.approve(address(NPM), type(uint256).max);
        IERC20(USDC).approve(address(NPM), type(uint256).max);
        // G at 1.00 USDC on v3, 1.06 on v4: buy on v3, sell on v4.
        v3Pool = _v3FullRange(1_000_000e18, 1_000_000e6);
        v4Key = _key(USDC, 3000, 60);
        _v4(v4Key, _sqrtPrice(USDC, 1_000_000e18, 1_060_000e6), 1e18);
    }
    // ---- helpers ----
    function _key(address quote, uint24 fee, int24 spacing) internal view returns (PoolKey memory) {
        (address c0, address c1) = quote < address(g) ? (quote, address(g)) : (address(g), quote);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, spacing, IHooks(address(0)));
    }
    /// @dev sqrt(token1/token0) in Q96 for `gAmount` of G against `quoteAmount` of `quote`.
    function _sqrtPrice(address quote, uint256 gAmount, uint256 quoteAmount) internal view returns (uint160) {
        uint256 ratio = address(g) < quote ? Math.mulDiv(quoteAmount, 1 << 192, gAmount) : Math.mulDiv(gAmount, 1 << 192, quoteAmount);
        return SafeCast.toUint160(Math.sqrt(ratio));
    }
    function _v4(PoolKey memory key, uint160 sqrtPrice, uint256 liquidity) internal {
        PM.initialize(key, sqrtPrice);
        provider.addLiquidity(key, liquidity);
    }
    function _v3FullRange(uint256 gAmount, uint256 usdcAmount) internal returns (address pool) {
        (address t0, address t1) = USDC < address(g) ? (USDC, address(g)) : (address(g), USDC);
        NPM.createAndInitializePoolIfNecessary(t0, t1, 3000, _sqrtPrice(USDC, gAmount, usdcAmount));
        (uint256 a0, uint256 a1) = t0 == USDC ? (usdcAmount, gAmount) : (gAmount, usdcAmount);
        NPM.mint(
            INonfungiblePositionManager.MintParams(
                t0, t1, 3000, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), a0, a1, 0, 0, address(this), block.timestamp
            )
        );
        pool = V3_FACTORY.getPool(t0, t1, 3000);
    }
    function _v3Leg(address tokenIn, address tokenOut) internal view returns (CovenProbe.Leg memory leg) {
        leg.pool = v3Pool;
        leg.tokenIn = tokenIn;
        leg.tokenOut = tokenOut;
        leg.zeroForOne = tokenIn < tokenOut;
        leg.feePips = 3000;
    }
    function _v4Leg(PoolKey memory key, address tokenIn) internal pure returns (CovenProbe.Leg memory leg) {
        leg.v4 = true;
        leg.key = key;
        leg.zeroForOne = Currency.unwrap(key.currency0) == tokenIn;
    }
    function _route(CovenProbe.Leg memory a, CovenProbe.Leg memory b, uint256 amountIn, bool sized)
        internal
        pure
        returns (CovenProbe.Route memory r)
    {
        r.legs = new CovenProbe.Leg[](2);
        r.legs[0] = a;
        r.legs[1] = b;
        r.amountIn = amountIn;
        r.minProfit = 1;
        r.sized = sized;
        r.check = true;
    }
    function _one(CovenProbe.Route memory r) internal pure returns (CovenProbe.Route[] memory rs) {
        rs = new CovenProbe.Route[](1);
        rs[0] = r;
    }
    function _probe(CovenProbe.Route memory r) internal returns (uint256) {
        vm.prank(executor);
        return probe.probe(_one(r), 1000)[0];
    }
    function _buyV3SellV4(uint256 amountIn, bool sized) internal view returns (CovenProbe.Route memory) {
        return _route(_v3Leg(USDC, address(g)), _v4Leg(v4Key, address(g)), amountIn, sized);
    }
    function _assertProbeEmpty() internal view {
        assertEq(IERC20(USDC).balanceOf(address(probe)), 0, "probe usdc");
        assertEq(g.balanceOf(address(probe)), 0, "probe G");
    }
    // ---- sizing ----
    function test_sizedTwoLegNearBestFixedSize() public {
        uint256 best;
        uint256 bestAmount;
        for (uint256 amount = 1_000e6; amount <= 64_000e6; amount = amount * 125 / 100) {
            uint256 snap = vm.snapshotState();
            uint256 p = _probe(_buyV3SellV4(amount, false));
            vm.revertToState(snap);
            if (p > best) (best, bestAmount) = (p, amount);
        }
        assertGt(best, 0, "grid found nothing");
        uint256 before = IERC20(USDC).balanceOf(executor);
        uint256 sized = _probe(_buyV3SellV4(10_000_000e6, true));
        emit log_named_uint("best fixed-size profit", best);
        emit log_named_uint("best fixed size", bestAmount);
        emit log_named_uint("sized profit", sized);
        assertGe(sized * 1000, best * 990, "sized below 99% of the best grid size");
        assertEq(IERC20(USDC).balanceOf(executor) - before, sized, "caller payout");
        _assertProbeEmpty();
    }
    function test_sizedRespectsCap() public {
        uint256 capped = _probe(_buyV3SellV4(1_000e6, true));
        assertGt(capped, 0);
        assertLt(capped, 1_000e6);
    }
    // ---- quiet returns ----
    function test_noGapReturnsZeroCheaply() public {
        // Wrong way round: sell on the cheap pool, buy on the dear one.
        CovenProbe.Route memory r = _route(_v4Leg(v4Key, USDC), _v3Leg(address(g), USDC), 1_000e6, false);
        vm.prank(executor);
        uint256 g0 = gasleft();
        uint256 p = probe.probe(_one(r), 1000)[0];
        uint256 used = g0 - gasleft();
        emit log_named_uint("no-gap check gas (2 legs, v3 + v4, excl. intrinsic)", used);
        assertEq(p, 0);
        assertLt(used, 40_000, "no-gap path too expensive");
    }
    function test_tradeThatNoLongerPaysReturnsZero() public {
        CovenProbe.Route memory r = _buyV3SellV4(1_000e6, true);
        r.minProfit = 1e30;
        uint256 before = IERC20(USDC).balanceOf(executor);
        assertEq(_probe(r), 0);
        assertEq(IERC20(USDC).balanceOf(executor), before, "paid out on a failed trade");
        _assertProbeEmpty();
    }
    function test_uncheckedLosingTradeReturnsZero() public {
        CovenProbe.Route memory r = _route(_v4Leg(v4Key, USDC), _v3Leg(address(g), USDC), 1_000e6, false);
        r.check = false;
        assertEq(_probe(r), 0);
        _assertProbeEmpty();
    }
    function test_manyRoutesOneCall() public {
        CovenProbe.Route[] memory rs = new CovenProbe.Route[](3);
        rs[0] = _route(_v4Leg(v4Key, USDC), _v3Leg(address(g), USDC), 1_000e6, false);
        rs[1] = _buyV3SellV4(1_000_000e6, true);
        rs[2] = _buyV3SellV4(1_000_000e6, true); // the gap is gone after rs[1]
        vm.prank(executor);
        uint256[] memory p = probe.probe(rs, 1000);
        assertEq(p[0], 0);
        assertGt(p[1], 0);
        assertEq(p[2], 0);
    }
    function test_invalidRouteReturnsZero() public {
        CovenProbe.Route memory r = _buyV3SellV4(0, false);
        r.check = false;
        assertEq(_probe(r), 0);
    }
    function test_closedGateSkipsRoute() public {
        CovenProbe.Route memory r = _buyV3SellV4(1_000_000e6, true);
        r.gate = CovenProbe.Gate(USDC, abi.encodeCall(IERC20.balanceOf, (address(0xdead))), 0, type(uint256).max);
        vm.prank(executor);
        uint256 g0 = gasleft();
        uint256 p = probe.probe(_one(r), 1000)[0];
        emit log_named_uint("closed gate gas", g0 - gasleft());
        assertEq(p, 0);
    }
    function test_openGateTrades() public {
        CovenProbe.Route memory r = _buyV3SellV4(1_000_000e6, true);
        r.gate = CovenProbe.Gate(USDC, abi.encodeCall(IERC20.balanceOf, (address(PM))), 0, 1);
        assertGt(_probe(r), 0);
    }
    function test_firstAtPriceSwapsNothingWithoutHook() public {
        CovenProbe.Route memory r = _buyV3SellV4(1_000_000e6, false);
        r.legs[0] = _v4Leg(v4Key, USDC);
        r.legs[1] = _v3Leg(address(g), USDC);
        r.firstAtPrice = true;
        r.check = false;
        assertEq(_probe(r), 0);
        _assertProbeEmpty();
    }
    function test_sizedWithFirstAtPriceInvalid() public {
        CovenProbe.Route memory r = _buyV3SellV4(1_000e6, true);
        r.firstAtPrice = true;
        assertEq(_probe(r), 0);
    }
    // ---- native USDC ----
    function test_erc20InNativeOut() public {
        PoolKey memory nk = _key(address(0), 3000, 60);
        _v4(nk, _sqrtPrice(address(0), 1_000_000e18, 1_060_000e18), 1e24);
        uint256 before = executor.balance;
        uint256 p = _probe(_route(_v3Leg(USDC, address(g)), _v4Leg(nk, address(g)), 10_000_000e6, true));
        assertGt(p, 0, "no profit");
        assertGe(executor.balance - before, p * 1e12, "native payout");
        _assertProbeEmpty();
        assertLt(address(probe).balance, 1e12, "native dust");
    }
    function test_nativeInErc20Out() public {
        PoolKey memory nk = _key(address(0), 3000, 60);
        _v4(nk, _sqrtPrice(address(0), 1_000_000e18, 940_000e18), 1e24);
        uint256 before = IERC20(USDC).balanceOf(executor);
        uint256 p = _probe(_route(_v4Leg(nk, address(0)), _v3Leg(address(g), USDC), 10_000_000e18, true));
        assertGt(p, 0, "no profit");
        assertGe(IERC20(USDC).balanceOf(executor) - before, p, "usdc payout");
        _assertProbeEmpty();
        assertLt(address(probe).balance, 1e12, "native dust");
    }
    // ---- access ----
    function test_feeGoesToRecipientAsClaims() public {
        uint256 id = uint256(uint160(USDC));
        uint256 before = IERC20(USDC).balanceOf(executor);
        vm.prank(executor);
        vm.recordLogs();
        uint256 net = probe.probe(_one(_buyV3SellV4(10_000_000e6, true)), 1000)[0];
        uint256 fee = PM.balanceOf(feeTo, id);
        assertGt(net, 0);
        assertEq(IERC20(USDC).balanceOf(executor) - before, net, "caller gets the net");
        // fee = 10% of gross, gross = net + fee (up to rounding)
        assertApproxEqAbs(fee * 9, net, 9, "fee is 10% of gross");
        assertEq(PM.balanceOf(address(probe), id), 0, "probe holds no claims");
    }
    function test_anyoneCanCall() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        assertGt(probe.probe(_one(_buyV3SellV4(1_000_000e6, true)), 1000)[0], 0);
    }
    function test_feeAboveCallerMaxReverts() public {
        vm.expectRevert(abi.encodeWithSelector(CovenProbe.FeeAbovePlanLimit.selector, uint16(1000), uint16(999)));
        probe.probe(_one(_buyV3SellV4(1_000e6, true)), 999);
    }
    function test_zeroFeePaysAllToCaller() public {
        vm.prank(owner);
        probe.setFee(0);
        vm.prank(executor);
        assertGt(probe.probe(_one(_buyV3SellV4(1_000_000e6, true)), 0)[0], 0);
        assertEq(PM.balanceOf(feeTo, uint256(uint160(USDC))), 0);
    }
    function test_runOnlyFromSelf() public {
        vm.expectRevert(CovenProbe.NotSelf.selector);
        probe.run(_buyV3SellV4(1_000e6, true));
    }
    function test_forgedCallbacksRevert() public {
        vm.expectRevert(CovenProbe.UnexpectedCallback.selector);
        probe.uniswapV3SwapCallback(1e6, 0, "");
        vm.prank(v3Pool);
        vm.expectRevert(CovenProbe.UnexpectedCallback.selector);
        probe.synthraV3SwapCallback(1e6, 0, "");
    }
    function test_unlockCallbackOnlyPoolManager() public {
        vm.expectRevert(CovenProbe.NotPoolManager.selector);
        probe.unlockCallback("");
    }
    function test_nativeOnlyFromPoolManager() public {
        (bool ok,) = address(probe).call{value: 1}("");
        assertFalse(ok);
    }
    function test_ownerAdmin() public {
        vm.expectRevert();
        probe.setFee(500);
        vm.startPrank(owner);
        vm.expectRevert(CovenProbe.InvalidFee.selector);
        probe.setFee(2001);
        probe.setFee(500);
        probe.setFeeRecipient(address(0xB0B));
        vm.expectRevert(CovenProbe.InvalidAddress.selector);
        probe.setFeeRecipient(address(0));
        vm.expectRevert(CovenProbe.OwnershipCannotBeRenounced.selector);
        probe.renounceOwnership();
        vm.stopPrank();
        assertEq(probe.feeBps(), 500);
        assertEq(probe.feeRecipient(), address(0xB0B));
    }
}
