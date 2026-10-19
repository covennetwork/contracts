// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CovenProbe2} from "../src/CovenProbe2.sol";
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
///   arc-forge test --match-contract CovenProbe2Test
contract CovenProbe2Test is Test {
    IPoolManager internal constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant UNI_V3_500 = 0x69BfaF19C9f377BB306a89aEd9F6B07e2c1a8d9a;
    address internal constant FORK_500 = 0x9B050cb1F265094b0977160a2BD7dA8C9E529c3C; // factory 0xe519…
    address internal constant SLIP_10 = 0x16679e2ac1A798865eCf1c1639e67693ddB1C220;
    CovenProbe2 internal probe;
    Pusher internal pusher;
    address internal owner = makeAddr("owner");
    address internal feeTo = makeAddr("feeTo");
    address internal caller = makeAddr("caller");
    function setUp() public {
        vm.createSelectFork("robinhood");
        probe = new CovenProbe2(owner, feeTo, 1000, PM, WETH);
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
    function _v4Leg(PoolKey memory key, bool zeroForOne) internal pure returns (CovenProbe2.Leg memory leg) {
        leg.v4 = true;
        leg.key = key;
        leg.zeroForOne = zeroForOne;
    }
    function _v3Leg(address pool, address tokenIn, address tokenOut, uint24 fee) internal pure returns (CovenProbe2.Leg memory leg) {
        leg.pool = pool;
        leg.tokenIn = tokenIn;
        leg.tokenOut = tokenOut;
        leg.zeroForOne = tokenIn < tokenOut;
        leg.feePips = fee;
    }
    function _route(CovenProbe2.Leg memory a, CovenProbe2.Leg memory b, uint256 amountIn, bool sized)
        internal
        pure
        returns (CovenProbe2.Route[] memory routes)
    {
        routes = new CovenProbe2.Route[](1);
        routes[0].legs = new CovenProbe2.Leg[](2);
        routes[0].legs[0] = a;
        routes[0].legs[1] = b;
        routes[0].amountIn = amountIn;
        routes[0].minProfit = 1;
        routes[0].sized = sized;
        routes[0].check = true;
    }
    function _probe(CovenProbe2.Route[] memory routes) internal returns (uint256) {
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
        CovenProbe2.Route[] memory routes = new CovenProbe2.Route[](1);
        routes[0].legs = new CovenProbe2.Leg[](3);
        routes[0].legs[0] = _v3Leg(UNI_V3_500, USDG, WETH, 500);
        routes[0].legs[1] = _v4Leg(_nativeKey(500, 10), true); // WETH credit is converted to ETH
        routes[0].legs[2] = _v4Leg(_nativeKey(3000, 60), false); // USDG -> ETH again: not a cycle
        routes[0].amountIn = 1000e6;
        routes[0].minProfit = 1;
        routes[0].check = false;
        // Starts in USDG, ends in ETH: rejected, so 0.
        assertEq(_probe(routes), 0);
        routes[0].legs = new CovenProbe2.Leg[](2);
        routes[0].legs[0] = _v3Leg(UNI_V3_500, USDG, WETH, 500);
        routes[0].legs[1] = _v4Leg(_nativeKey(500, 10), true);
        assertGt(_probe(routes), 0);
    }
    function test_feeLimitAndAccess() public {
        CovenProbe2.Route[] memory routes = new CovenProbe2.Route[](0);
        vm.expectRevert(abi.encodeWithSelector(CovenProbe2.FeeAbovePlanLimit.selector, 1000, 999));
        probe.probe(routes, 999);
        vm.expectRevert(CovenProbe2.UnexpectedCallback.selector);
        payable(address(probe)).transfer(1);
        CovenProbe2.Route memory r = _route(_v4Leg(_nativeKey(500, 10), true), _v4Leg(_nativeKey(500, 10), false), 1, false)[0];
        vm.expectRevert(CovenProbe2.NotSelf.selector);
        probe.run(r);
        vm.expectRevert(CovenProbe2.OwnershipCannotBeRenounced.selector);
        vm.prank(owner);
        probe.renounceOwnership();
        vm.expectRevert(CovenProbe2.InvalidFee.selector);
        vm.prank(owner);
        probe.setFee(2001);
    }
}
