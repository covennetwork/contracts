// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ICovenRouter} from "../../src/interfaces/ICovenRouter.sol";
import {CovenRouter} from "../../src/CovenRouter.sol";
import {ICovenRouter} from "../../src/interfaces/ICovenRouter.sol";
import {MockERC20, MockSwapRouter02, MockPoolManager, MockTokenMessenger, ReentrantToken} from "./Mocks.sol";

contract SwapAudit is Test {
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant SWAP_ROUTER_02 = 0x53BF6B0684Ec7eF91e1387Da3D1a1769bC5A6F77;
    address constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;

    uint16 constant FEE = 30; // 0.30% platform fee

    CovenRouter router;
    MockPoolManager pm;
    MockSwapRouter02 v3;
    MockTokenMessenger cctp;
    MockERC20 tokenA;
    MockERC20 tokenB;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address guardian = makeAddr("guardian");
    address partner = makeAddr("partner");
    address user = makeAddr("user");

    function setUp() public {
        deployCodeTo("Mocks.sol:MockERC20", abi.encode("USD Coin", "USDC"), USDC);
        deployCodeTo("Mocks.sol:MockPoolManager", "", POOL_MANAGER);
        deployCodeTo("Mocks.sol:MockSwapRouter02", "", SWAP_ROUTER_02);
        deployCodeTo("Mocks.sol:MockTokenMessenger", "", TOKEN_MESSENGER);
        pm = MockPoolManager(POOL_MANAGER);
        v3 = MockSwapRouter02(SWAP_ROUTER_02);
        cctp = MockTokenMessenger(TOKEN_MESSENGER);

        router = new CovenRouter(owner, treasury, guardian, FEE, new address[](0), new ICovenRouter.TemplateInit[](0));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");

        // fund user
        MockERC20(USDC).mint(user, 1_000_000e6);
        tokenA.mint(user, 1_000_000e18);
        tokenB.mint(user, 1_000_000e18);

        vm.startPrank(user);
        MockERC20(USDC).approve(address(router), type(uint256).max);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _fee(uint256 amt, uint256 bps) internal pure returns (uint256) {
        return amt * bps / 10_000;
    }

    function _v3(address tokenOut) internal pure returns (ICovenRouter.Hop memory) {
        return ICovenRouter.Hop(ICovenRouter.Protocol.V3, tokenOut, 3000, 0, address(0));
    }

    function _v4(address tokenOut) internal pure returns (ICovenRouter.Hop memory) {
        return ICovenRouter.Hop(ICovenRouter.Protocol.V4, tokenOut, 3000, 60, address(0));
    }

    function _one(ICovenRouter.Hop memory h) internal pure returns (ICovenRouter.Hop[] memory a) {
        a = new ICovenRouter.Hop[](1);
        a[0] = h;
    }

    function _two(ICovenRouter.Hop memory h1, ICovenRouter.Hop memory h2)
        internal
        pure
        returns (ICovenRouter.Hop[] memory a)
    {
        a = new ICovenRouter.Hop[](2);
        a[0] = h1;
        a[1] = h2;
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

    function _assertRouterEmpty() internal view {
        assertEq(MockERC20(USDC).balanceOf(address(router)), 0, "router usdc");
        assertEq(tokenA.balanceOf(address(router)), 0, "router A");
        assertEq(tokenB.balanceOf(address(router)), 0, "router B");
    }

    // ---- buying with USDC: fees taken from USDC input ----
    function test_buyFeeOnInput() public {
        uint256 amountIn = 1_000e6;
        uint256 pf = _fee(amountIn, FEE);
        uint256 inf = _fee(amountIn, 50);
        uint256 expected = amountIn - pf - inf; // 1:1 rate

        ICovenRouter.SwapParams memory p = _params(USDC, amountIn, _one(_v3(address(tokenA))), expected);
        p.integrator = partner;
        p.integratorFeeBps = 50;

        vm.prank(user);
        uint256 out = router.swap(p, user);
        assertEq(out, expected, "out");
        assertEq(tokenA.balanceOf(user), 1_000_000e18 + expected, "user got A");
        assertEq(MockERC20(USDC).balanceOf(treasury), pf, "platform fee");
        assertEq(MockERC20(USDC).balanceOf(partner), inf, "integrator fee");
        _assertRouterEmpty();
    }

    // ---- selling for USDC: fees taken from USDC output ----
    function test_sellFeeOnOutput() public {
        uint256 amountIn = 500e18;
        uint256 gross = amountIn; // 1:1
        uint256 pf = _fee(gross, FEE);
        uint256 net = gross - pf;

        address recipient = makeAddr("recipient");
        vm.prank(user);
        uint256 out = router.swap(_params(address(tokenA), amountIn, _one(_v3(USDC)), net), recipient);
        assertEq(out, net, "net out");
        assertEq(MockERC20(USDC).balanceOf(recipient), net, "recipient usdc");
        assertEq(MockERC20(USDC).balanceOf(treasury), pf, "platform fee");
        assertEq(tokenA.balanceOf(treasury), 0, "no A fee");
        _assertRouterEmpty();
    }

    // ---- neither side USDC: fee on input token ----
    function test_neitherUsdcFeeOnInput() public {
        uint256 amountIn = 400e18;
        uint256 pf = _fee(amountIn, FEE);
        uint256 expected = amountIn - pf;
        vm.prank(user);
        uint256 out = router.swap(_params(address(tokenA), amountIn, _one(_v4(address(tokenB))), expected), user);
        assertEq(out, expected);
        assertEq(tokenA.balanceOf(treasury), pf, "A platform fee");
        _assertRouterEmpty();
    }

    // ---- multi-hop V3 then V4 ending in USDC: fee on output only ----
    function test_multiHopV3ThenV4FeeOnOutput() public {
        uint256 amountIn = 300e18;
        // A ->(V3) B ->(V4) USDC, 1:1 each
        uint256 gross = amountIn;
        uint256 pf = _fee(gross, FEE);
        uint256 net = gross - pf;
        ICovenRouter.Hop[] memory hops = _two(_v3(address(tokenB)), _v4(USDC));
        uint256 beforeBal = MockERC20(USDC).balanceOf(user);
        vm.prank(user);
        uint256 out = router.swap(_params(address(tokenA), amountIn, hops, net), user);
        assertEq(out, net, "net");
        assertEq(MockERC20(USDC).balanceOf(treasury), pf);
        assertEq(MockERC20(USDC).balanceOf(user) - beforeBal, net);
        _assertRouterEmpty();
    }

    // ---- minAmountOut enforced after fees ----
    function test_minAmountOutEnforced() public {
        uint256 amountIn = 500e18;
        uint256 gross = amountIn;
        uint256 net = gross - _fee(gross, FEE);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ICovenRouter.InsufficientOutput.selector, net, gross));
        router.swap(_params(address(tokenA), amountIn, _one(_v3(USDC)), gross), user);
    }

    // ---- exact-fill guards ----
    function test_partialFillV3Reverts() public {
        v3.setConsumeLess(true);
        vm.prank(user);
        vm.expectRevert(ICovenRouter.PartialFill.selector);
        router.swap(_params(USDC, 1_000e6, _one(_v3(address(tokenA))), 1), user);
    }

    function test_partialFillV4Reverts() public {
        pm.setUnderfillInput(true);
        vm.prank(user);
        vm.expectRevert(ICovenRouter.PartialFill.selector);
        router.swap(_params(address(tokenA), 100e18, _one(_v4(address(tokenB))), 1), user);
    }

    function test_zeroOutputV4Reverts() public {
        pm.setZeroOutput(true);
        vm.prank(user);
        vm.expectRevert(ICovenRouter.ZeroAmount.selector);
        router.swap(_params(address(tokenA), 100e18, _one(_v4(address(tokenB))), 1), user);
    }

    // ---- swapAndBridge ----
    function test_swapAndBridgeWithHook() public {
        uint256 amountIn = 500e18;
        uint256 net = amountIn - _fee(amountIn, FEE);
        bytes32 recip = bytes32(uint256(uint160(user)));
        ICovenRouter.BridgeParams memory b = ICovenRouter.BridgeParams({
            destinationDomain: 6,
            mintRecipient: recip,
            destinationCaller: bytes32(0),
            maxFee: 0,
            minFinalityThreshold: 2000,
            hookData: hex"deadbeef"
        });
        vm.prank(user);
        uint256 bridged = router.swapAndBridge(_params(address(tokenA), amountIn, _one(_v3(USDC)), net), b);
        assertEq(bridged, net);
        assertEq(cctp.lastAmount(), net, "burned net");
        assertEq(cctp.lastDomain(), 6);
        assertTrue(cctp.hookPathUsed(), "hook path");
        assertEq(IERC20(USDC).allowance(address(router), TOKEN_MESSENGER), 0, "allowance cleared");
        _assertRouterEmpty();
    }

    function test_swapAndBridgeNoHook() public {
        uint256 amountIn = 200e18;
        uint256 net = amountIn - _fee(amountIn, FEE);
        bytes32 recip = bytes32(uint256(uint160(user)));
        ICovenRouter.BridgeParams memory b =
            ICovenRouter.BridgeParams(3, recip, bytes32(0), 0, 2000, "");
        vm.prank(user);
        assertEq(router.swapAndBridge(_params(address(tokenA), amountIn, _one(_v3(USDC)), net), b), net);
        assertEq(cctp.lastAmount(), net);
        assertFalse(cctp.hookPathUsed());
        _assertRouterEmpty();
    }

    function test_swapAndBridgeRejectsNonUsdcAndBadParams() public {
        bytes32 recip = bytes32(uint256(uint160(user)));
        ICovenRouter.BridgeParams memory b = ICovenRouter.BridgeParams(6, recip, bytes32(0), 0, 2000, "");
        // ends in tokenA, not USDC
        vm.prank(user);
        vm.expectRevert(ICovenRouter.BridgeRequiresUsdc.selector);
        router.swapAndBridge(_params(USDC, 100e6, _one(_v3(address(tokenA))), 1), b);

        // local domain
        b.destinationDomain = 26;
        vm.prank(user);
        vm.expectRevert(ICovenRouter.InvalidDestination.selector);
        router.swapAndBridge(_params(address(tokenA), 100e18, _one(_v3(USDC)), 1), b);

        // zero recipient
        b.destinationDomain = 6;
        b.mintRecipient = bytes32(0);
        vm.prank(user);
        vm.expectRevert(ICovenRouter.InvalidRecipient.selector);
        router.swapAndBridge(_params(address(tokenA), 100e18, _one(_v3(USDC)), 1), b);
    }

    // ---- integrator fee validation ----
    function test_integratorFeeValidation() public {
        ICovenRouter.Hop[] memory hops = _one(_v3(address(tokenA)));
        // fee set but no integrator
        ICovenRouter.SwapParams memory p = _params(USDC, 100e6, hops, 1);
        p.integratorFeeBps = 10;
        vm.prank(user);
        vm.expectRevert(ICovenRouter.InvalidIntegratorFee.selector);
        router.swap(p, user);

        // fee above cap
        p.integrator = partner;
        p.integratorFeeBps = 301;
        vm.prank(user);
        vm.expectRevert(ICovenRouter.InvalidIntegratorFee.selector);
        router.swap(p, user);

        // integrator == router
        p.integrator = address(router);
        p.integratorFeeBps = 10;
        vm.prank(user);
        vm.expectRevert(ICovenRouter.InvalidIntegratorFee.selector);
        router.swap(p, user);
    }

    // ---- basic guards ----
    function test_deadlineAndZeroChecks() public {
        ICovenRouter.Hop[] memory hops = _one(_v3(address(tokenA)));
        ICovenRouter.SwapParams memory p = _params(USDC, 100e6, hops, 1);
        p.deadline = block.timestamp - 1;
        vm.prank(user);
        vm.expectRevert(ICovenRouter.Expired.selector);
        router.swap(p, user);

        p = _params(USDC, 100e6, hops, 0);
        vm.prank(user);
        vm.expectRevert(ICovenRouter.ZeroMinAmountOut.selector);
        router.swap(p, user);

        p = _params(USDC, 0, hops, 1);
        vm.prank(user);
        vm.expectRevert(ICovenRouter.ZeroAmount.selector);
        router.swap(p, user);

        vm.prank(user);
        vm.expectRevert(ICovenRouter.InvalidRecipient.selector);
        router.swap(_params(USDC, 100e6, hops, 1), address(0));

        vm.prank(user);
        vm.expectRevert(ICovenRouter.InvalidRecipient.selector);
        router.swap(_params(USDC, 100e6, hops, 1), address(router));
    }

    function test_pauseBlocksSwap() public {
        vm.prank(guardian);
        router.pause();
        vm.prank(user);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.swap(_params(USDC, 100e6, _one(_v3(address(tokenA))), 1), user);
    }

    // ---- stray-token isolation: donated balances are not paid to swappers ----
    function test_donatedTokensNotStolenBySwapper() public {
        // Someone accidentally sends tokenA to the router.
        tokenA.mint(address(router), 123e18);
        // A buy USDC->tokenA should still pay exactly the swap output, leaving the donation.
        uint256 amountIn = 100e6;
        uint256 expected = amountIn - _fee(amountIn, FEE);
        vm.prank(user);
        uint256 out = router.swap(_params(USDC, amountIn, _one(_v3(address(tokenA))), expected), user);
        assertEq(out, expected, "output is swap-only, not donation");
        assertEq(tokenA.balanceOf(address(router)), 123e18, "donation still there for owner sweep");
    }

    // ---- reentrancy: a malicious output token cannot reenter swap ----
    function test_reentrancyGuardBlocksMaliciousOutputToken() public {
        ReentrantToken evil = new ReentrantToken();
        // user buys the evil token with USDC via V3
        ICovenRouter.SwapParams memory inner =
            _params(USDC, 10e6, _one(_v3(address(evil))), 1);
        // when the router pays the evil token out to `user`, it reenters router.swap
        evil.arm(address(router), abi.encodeCall(CovenRouter.swap, (inner, user)));

        ICovenRouter.SwapParams memory outer = _params(USDC, 100e6, _one(_v3(address(evil))), 1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        router.swap(outer, user);
    }

    // ---- fuzz: buy output is always input minus fees at 1:1 ----
    function testFuzz_buyFeeMath(uint256 amountIn, uint16 integBps) public {
        amountIn = bound(amountIn, 1e6, 500_000e6);
        integBps = uint16(bound(integBps, 0, 300));
        MockERC20(USDC).mint(user, amountIn);
        uint256 pf = _fee(amountIn, FEE);
        uint256 inf = _fee(amountIn, integBps);
        uint256 expected = amountIn - pf - inf;
        ICovenRouter.SwapParams memory p = _params(USDC, amountIn, _one(_v3(address(tokenA))), expected);
        if (integBps != 0) {
            p.integrator = partner;
            p.integratorFeeBps = integBps;
        }
        vm.prank(user);
        assertEq(router.swap(p, user), expected);
        assertEq(MockERC20(USDC).balanceOf(treasury), pf);
        if (integBps != 0) assertEq(MockERC20(USDC).balanceOf(partner), inf);
        _assertRouterEmpty();
    }
}
