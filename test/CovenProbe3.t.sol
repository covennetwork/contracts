// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CovenProbe3} from "../src/CovenProbe3.sol";
interface IPushPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256, int256);
}
interface IWeth {
    function deposit() external payable;
}
/// @dev Moves a v3-style pool's price by trading into it, to open a gap against its siblings.
contract Pusher {
    function push(address pool, bool zeroForOne, int256 amount) external {
        IPushPool(pool).swap(
            address(this), zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1, ""
        );
    }
    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        if (a0 > 0) require(IERC20(IPushPool(msg.sender).token0()).transfer(msg.sender, uint256(a0)), "pay0");
        if (a1 > 0) require(IERC20(IPushPool(msg.sender).token1()).transfer(msg.sender, uint256(a1)), "pay1");
    }
}
/// @notice CovenProbe2 on real Robinhood Chain pools, forked at a fixed block: native ETH v4
/// pools against WETH v3-style pools (Uniswap v3, a v3 fork, a Slipstream clone). Public RPCs
/// keep only minutes of state, so the fork is at the latest block.
///   arc-forge test --match-contract CovenProbe3Test
contract CovenProbe3Test is Test {
    IPoolManager internal constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant UNI_V3_500 = 0x69BfaF19C9f377BB306a89aEd9F6B07e2c1a8d9a;
    address internal constant FORK_500 = 0x9B050cb1F265094b0977160a2BD7dA8C9E529c3C; // factory 0xe519…
    address internal constant SLIP_10 = 0x16679e2ac1A798865eCf1c1639e67693ddB1C220;
    CovenProbe3 internal probe;
    Pusher internal pusher;
    address internal owner = makeAddr("owner");
    address internal feeTo = makeAddr("feeTo");
    address internal caller = makeAddr("caller");
    function setUp() public {
        vm.createSelectFork("robinhood");
        probe = new CovenProbe3(owner, feeTo, 1000, PM, WETH);
        pusher = new Pusher();
        vm.deal(address(this), 1000 ether);
        IWeth(WETH).deposit{value: 500 ether}();
        require(IERC20(WETH).transfer(address(pusher), 500 ether), "fund");
    }
    // ---- helpers ----
    function _nativeKey(uint24 fee, int24 spacing) internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(USDG), fee, spacing, IHooks(address(0)));
    }
    function _wethKey(uint24 fee, int24 spacing) internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(WETH), Currency.wrap(USDG), fee, spacing, IHooks(address(0)));
    }
    function _v4Leg(PoolKey memory key, bool zeroForOne) internal pure returns (CovenProbe3.Leg memory leg) {
        leg.kind = 1;
        leg.key = key;
        leg.zeroForOne = zeroForOne;
    }
    function _v3Leg(address pool, address tokenIn, address tokenOut, uint24 fee) internal pure returns (CovenProbe3.Leg memory leg) {
        leg.pool = pool;
        leg.tokenIn = tokenIn;
        leg.tokenOut = tokenOut;
        leg.zeroForOne = tokenIn < tokenOut;
        leg.feePips = fee;
    }
    function _route(CovenProbe3.Leg memory a, CovenProbe3.Leg memory b, uint256 amountIn, bool sized)
        internal
        pure
        returns (CovenProbe3.Route[] memory routes)
    {
        routes = new CovenProbe3.Route[](1);
        routes[0].legs = new CovenProbe3.Leg[](2);
        routes[0].legs[0] = a;
        routes[0].legs[1] = b;
        routes[0].amountIn = amountIn;
        routes[0].minProfit = 1;
        routes[0].sized = sized;
        routes[0].check = true;
    }
    function _probe(CovenProbe3.Route[] memory routes) internal returns (uint256) {
        vm.prank(caller);
        return probe.probe(routes, 1000)[0];
    }
    /// @dev Make WETH cheap in a WETH/USDG v3-style pool (WETH is token0).
    function _dumpWeth(address pool, uint256 amount) internal {
        pusher.push(pool, true, int256(amount));
    }
    // ---- tests ----
    function test_noGapReturnsZero() public {
        uint256 p = _probe(_route(_v3Leg(UNI_V3_500, USDG, WETH, 500), _v4Leg(_nativeKey(500, 10), true), 1e12, true));
        assertEq(p, 0);
    }
    /// USDG -> WETH (cheap v3) -> native ETH -> USDG (v4): converts WETH to ETH between legs.
    function test_usdgStartConvertsMidRoute() public {
        _dumpWeth(UNI_V3_500, 20 ether);
        uint256 before = IERC20(USDG).balanceOf(caller);
        uint256 p = _probe(_route(_v3Leg(UNI_V3_500, USDG, WETH, 500), _v4Leg(_nativeKey(500, 10), true), 1e12, true));
        assertGt(p, 0, "profit");
        assertEq(IERC20(USDG).balanceOf(caller) - before, p, "caller paid in USDG");
        assertGt(PM.balanceOf(feeTo, uint256(uint160(USDG))), 0, "fee as claims");
        assertEq(address(probe).balance, 0);
        assertEq(IERC20(WETH).balanceOf(address(probe)), 0);
    }
    /// ETH -> USDG (v4) -> WETH (cheap v3): ends in WETH and is settled back into ETH.
    function test_nativeStartEndsInWeth() public {
        _dumpWeth(UNI_V3_500, 20 ether);
        uint256 before = caller.balance;
        uint256 p = _probe(_route(_v4Leg(_nativeKey(500, 10), true), _v3Leg(UNI_V3_500, USDG, WETH, 500), 1e24, true));
        assertGt(p, 0, "profit");
        uint256 gotEth = caller.balance - before;
        uint256 gotWeth = IERC20(WETH).balanceOf(caller);
        assertEq(gotEth + gotWeth, p, "profit in ETH or WETH");
        assertEq(address(probe).balance, 0);
    }
    /// WETH -> USDG (v4 WETH pool) -> WETH (cheap v3): no conversion needed.
    function test_wethStart() public {
        _dumpWeth(UNI_V3_500, 20 ether);
        uint256 p = _probe(_route(_v4Leg(_wethKey(500, 10), true), _v3Leg(UNI_V3_500, USDG, WETH, 500), 1e24, true));
        assertGt(p, 0, "profit");
        assertEq(IERC20(WETH).balanceOf(caller), p);
    }
    /// A v3 fork (factory 0xe519…) and a Slipstream clone, both with uniswapV3SwapCallback.
    function test_forkAndSlipstreamVenues() public {
        _dumpWeth(FORK_500, 5 ether);
        uint256 p1 = _probe(_route(_v3Leg(FORK_500, USDG, WETH, 500), _v3Leg(UNI_V3_500, WETH, USDG, 500), 1e12, true));
        assertGt(p1, 0, "fork venue");
        _dumpWeth(SLIP_10, 5 ether);
        (bool ok, bytes memory ret) = SLIP_10.staticcall(abi.encodeWithSignature("fee()"));
        require(ok, "fee");
        uint24 slipFee = abi.decode(ret, (uint24));
        uint256 p2 = _probe(_route(_v3Leg(SLIP_10, USDG, WETH, slipFee), _v4Leg(_nativeKey(500, 10), true), 1e12, true));
        assertGt(p2, 0, "slipstream venue");
    }
    /// An unsized three-leg route through a fixed input.
    function test_threeLegsFixedInput() public {
        _dumpWeth(UNI_V3_500, 20 ether);
        CovenProbe3.Route[] memory routes = new CovenProbe3.Route[](1);
        routes[0].legs = new CovenProbe3.Leg[](3);
        routes[0].legs[0] = _v3Leg(UNI_V3_500, USDG, WETH, 500);
        routes[0].legs[1] = _v4Leg(_nativeKey(500, 10), true); // WETH credit is converted to ETH
        routes[0].legs[2] = _v4Leg(_nativeKey(3000, 60), false); // USDG -> ETH again: not a cycle
        routes[0].amountIn = 1000e6;
        routes[0].minProfit = 1;
        routes[0].check = false;
        // Starts in USDG, ends in ETH: rejected, so 0.
        assertEq(_probe(routes), 0);
        routes[0].legs = new CovenProbe3.Leg[](2);
        routes[0].legs[0] = _v3Leg(UNI_V3_500, USDG, WETH, 500);
        routes[0].legs[1] = _v4Leg(_nativeKey(500, 10), true);
        assertGt(_probe(routes), 0);
    }
    function test_feeLimitAndAccess() public {
        CovenProbe3.Route[] memory routes = new CovenProbe3.Route[](0);
        vm.expectRevert(abi.encodeWithSelector(CovenProbe3.FeeAbovePlanLimit.selector, 1000, 999));
        probe.probe(routes, 999);
        vm.expectRevert(CovenProbe3.UnexpectedCallback.selector);
        payable(address(probe)).transfer(1);
        CovenProbe3.Route memory r = _route(_v4Leg(_nativeKey(500, 10), true), _v4Leg(_nativeKey(500, 10), false), 1, false)[0];
        vm.expectRevert(CovenProbe3.NotSelf.selector);
        probe.run(r);
        vm.expectRevert(CovenProbe3.OwnershipCannotBeRenounced.selector);
        vm.prank(owner);
        probe.renounceOwnership();
        vm.expectRevert(CovenProbe3.InvalidFee.selector);
        vm.prank(owner);
        probe.setFee(2001);
    }

    // ---- v2 pairs and vault deposits (BASK) ----
    address internal constant BASK = 0x739fD5B653aA092a434534FA1aDE67C1770b5a5B;
    address internal constant BASK_PAIR = 0xCC23688c49D58c5FF1f3Bf77e3cAB1927cBa6e70; // Uniswap v2, USDG/BASK
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant USDG_WETH_100 = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address internal constant WETH_AAPL_500 = 0x8bb3514e2204E1cDF3Ac149EFEe7Ff04D91B719f;

    function _v2Leg(address pair, address tokenIn, address tokenOut) internal pure returns (CovenProbe3.Leg memory leg) {
        leg.kind = 2;
        leg.pool = pair;
        leg.tokenIn = tokenIn;
        leg.tokenOut = tokenOut;
        leg.zeroForOne = tokenIn < tokenOut;
        leg.feePips = 3000;
    }

    function _depositLeg(address vault, address tokenIn) internal pure returns (CovenProbe3.Leg memory leg) {
        leg.kind = 3;
        leg.pool = vault;
        leg.tokenIn = tokenIn;
        leg.tokenOut = vault;
    }

    /// USDG -> WETH -> AAPL (v3) -> BASK (deposit at the oracle price) -> USDG (v2 pair).
    function _mintRoute(uint256 amountIn) internal pure returns (CovenProbe3.Route[] memory routes) {
        routes = new CovenProbe3.Route[](1);
        routes[0].legs = new CovenProbe3.Leg[](4);
        routes[0].legs[0] = _v3Leg(USDG_WETH_100, USDG, WETH, 100);
        routes[0].legs[1] = _v3Leg(WETH_AAPL_500, WETH, AAPL, 500);
        routes[0].legs[2] = _depositLeg(BASK, AAPL);
        routes[0].legs[3] = _v2Leg(BASK_PAIR, BASK, USDG);
        routes[0].amountIn = amountIn;
        routes[0].minProfit = 1;
    }

    function _depositsOpen() internal view returns (bool) {
        (bool ok, bytes memory ret) = BASK.staticcall(abi.encodeWithSignature("depositStatus(address[])", _one(AAPL)));
        return ok && abi.decode(ret, (uint8)) == 0;
    }

    function _one(address a) internal pure returns (address[] memory xs) {
        xs = new address[](1);
        xs[0] = a;
    }

    /// Buy BASK on its v2 pair with `usdg`, lifting its price above NAV.
    function _liftBask(uint256 usdg) internal {
        vm.prank(USDG_WETH_100); // a pool that holds USDG funds the push
        require(IERC20(USDG).transfer(BASK_PAIR, usdg), "fund pair");
        (bool ok, bytes memory ret) = BASK_PAIR.staticcall(abi.encodeWithSignature("getReserves()"));
        require(ok, "reserves");
        (uint112 r0, uint112 r1,) = abi.decode(ret, (uint112, uint112, uint32));
        uint256 inAfterFee = usdg * 997;
        uint256 out = inAfterFee * r1 / (uint256(r0) * 1000 + inAfterFee);
        (ok,) = BASK_PAIR.call(abi.encodeWithSignature("swap(uint256,uint256,address,bytes)", 0, out, address(this), ""));
        require(ok, "swap");
    }

    function test_baskMintArb() public {
        if (!_depositsOpen()) vm.skip(true);
        _liftBask(3000e6);
        uint256 before = IERC20(USDG).balanceOf(caller);
        uint256 p = _probe(_mintRoute(300e6));
        assertGt(p, 0, "profit");
        assertEq(IERC20(USDG).balanceOf(caller) - before, p, "caller paid in USDG");
        assertGt(PM.balanceOf(feeTo, uint256(uint160(USDG))), 0, "fee as claims");
        assertEq(IERC20(AAPL).balanceOf(address(probe)), 0, "no AAPL left");
        assertEq(IERC20(BASK).balanceOf(address(probe)), 0, "no BASK left");
        assertEq(IERC20(AAPL).allowance(address(probe), BASK), 0, "approval cleared");
    }

    function test_baskNoPremiumReturnsZero() public {
        if (!_depositsOpen()) vm.skip(true);
        // At the fork BASK trades near NAV: minting pays the 0.5% deposit fee and the pair's
        // 0.3%, so the route loses and is skipped, not reverted.
        assertEq(_probe(_mintRoute(300e6)), 0);
    }

    function test_kindsTheChecksCannotPrice() public {
        CovenProbe3.Route[] memory routes = _mintRoute(300e6);
        routes[0].check = true; // a deposit has no pool price
        assertEq(_probe(routes), 0);
        routes = _route(_v2Leg(BASK_PAIR, USDG, BASK), _v2Leg(BASK_PAIR, BASK, USDG), 100e6, true); // sized v2
        assertEq(_probe(routes), 0);
        routes[0].legs[0].kind = 4; // unknown kind
        routes[0].sized = false;
        routes[0].check = false;
        assertEq(_probe(routes), 0);
    }
}
