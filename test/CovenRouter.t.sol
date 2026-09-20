// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ICovenRouter} from "../src/interfaces/ICovenRouter.sol";
import {ITokenMessengerV2} from "../src/interfaces/external/ITokenMessengerV2.sol";
contract CovenRouterTest is Fixture {
    bytes internal constant FORWARD_HOOK = hex"636374702d666f72776172640000000000000000000000000000000000000000";
    function test_buyWithUsdcChargesFeesInUsdcFromInput() public {
        uint256 amountIn = 1_000e6;
        uint256 platformFee = _fee(amountIn, PLATFORM_FEE_BPS);
        uint256 integratorFee = _fee(amountIn, 50);
        (ICovenRouter.Hop[] memory hops, uint256 expected) =
            _quote(USDC, address(tokenA), amountIn - platformFee - integratorFee);
        ICovenRouter.SwapParams memory p = _params(USDC, amountIn, hops, expected);
        p.integrator = partner;
        p.integratorFeeBps = 50;
        uint256 before = tokenA.balanceOf(user);
        vm.prank(user);
        uint256 out = router.swap(p, user);
        assertEq(out, expected);
        assertEq(tokenA.balanceOf(user) - before, expected);
        assertEq(IERC20(USDC).balanceOf(treasury), platformFee);
        assertEq(IERC20(USDC).balanceOf(partner), integratorFee);
        _assertRouterEmpty();
    }
    function test_sellForUsdcChargesFeesInUsdcFromOutput() public {
        uint256 amountIn = 750e18;
        (ICovenRouter.Hop[] memory hops, uint256 gross) = _quote(address(tokenA), USDC, amountIn);
        uint256 platformFee = _fee(gross, PLATFORM_FEE_BPS);
        uint256 integratorFee = _fee(gross, 50);
        uint256 net = gross - platformFee - integratorFee;
        ICovenRouter.SwapParams memory p = _params(address(tokenA), amountIn, hops, net);
        p.integrator = partner;
        p.integratorFeeBps = 50;
        address recipient = makeAddr("recipient");
        vm.prank(user);
        uint256 out = router.swap(p, recipient);
        assertEq(out, net);
        assertEq(IERC20(USDC).balanceOf(recipient), net);
        assertEq(IERC20(USDC).balanceOf(treasury), platformFee);
        assertEq(IERC20(USDC).balanceOf(partner), integratorFee);
        assertEq(tokenA.balanceOf(treasury), 0);
        _assertRouterEmpty();
    }
    function test_mixedV3ThenV4RouteMatchesQuote() public {
        uint256 amountIn = 500e18;
        uint256 platformFee = _fee(amountIn, PLATFORM_FEE_BPS);
        (ICovenRouter.Hop[] memory hops, uint256 expected) =
            _quote(address(tokenA), address(tokenB), amountIn - platformFee);
        assertEq(hops.length, 2);
        assertEq(uint8(hops[0].protocol), uint8(ICovenRouter.Protocol.V3));
        assertEq(uint8(hops[1].protocol), uint8(ICovenRouter.Protocol.V4));
        vm.prank(user);
        uint256 out = router.swap(_params(address(tokenA), amountIn, hops, expected), user);
        assertEq(out, expected);
        assertEq(tokenA.balanceOf(treasury), platformFee);
        _assertRouterEmpty();
    }
    function test_hookedPoolRequiresAllowlist() public {
        ICovenRouter.Hop[] memory hops = _one(_v4(address(tokenC), 10_000, 200, address(hookOne)));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ICovenRouter.HookNotAllowed.selector, address(hookOne)));
        router.swap(_params(USDC, 100e6, hops, 1), user);
        (ICovenRouter.Hop[] memory quoted, uint256 none) = _quote(USDC, address(tokenC), 100e6);
        assertEq(quoted.length, 0);
        assertEq(none, 0);
        vm.prank(owner);
        router.setHookAllowed(address(hookOne), true);
        uint256 swapIn = 100e6 - _fee(100e6, PLATFORM_FEE_BPS);
        (hops, none) = _quote(USDC, address(tokenC), swapIn);
        assertEq(hops[0].hooks, address(hookOne));
        vm.prank(user);
        assertEq(router.swap(_params(USDC, 100e6, hops, none), user), none);
        _assertRouterEmpty();
    }
    function test_hookTemplateCoversEveryDeploymentOfTheSameCode() public {
        assertFalse(router.isHookAllowed(address(hookTwo)));
        bytes32 id = _allowTemplateFrom(address(hookOne), address(hookTwo));
        assertTrue(router.isHookAllowed(address(hookOne)));
        assertTrue(router.isHookAllowed(address(hookTwo)));
        assertFalse(router.isHookAllowed(address(greedyHook)));
        uint256 swapIn = 100e6 - _fee(100e6, PLATFORM_FEE_BPS);
        (ICovenRouter.Hop[] memory hops, uint256 expected) = _quote(USDC, address(tokenE), swapIn);
        assertEq(hops[0].hooks, address(hookTwo));
        vm.prank(user);
        assertEq(router.swap(_params(USDC, 100e6, hops, expected), user), expected);
        vm.prank(owner);
        router.removeHookTemplate(id);
        assertFalse(router.isHookAllowed(address(hookTwo)));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ICovenRouter.HookNotAllowed.selector, address(hookTwo)));
        router.swap(_params(USDC, 100e6, hops, 1), user);
    }
    function test_unlistedHookIsRejectedEvenWhenTemplatesExist() public {
        _allowTemplateFrom(address(hookOne), address(hookTwo));
        ICovenRouter.Hop[] memory hops = _one(_v4(address(tokenF), 10_000, 200, address(greedyHook)));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ICovenRouter.HookNotAllowed.selector, address(greedyHook)));
        router.swap(_params(USDC, 100e6, hops, 1), user);
    }
    function test_partialFillReverts() public {
        ICovenRouter.Hop[] memory hops = _one(_v3(address(tokenD), 10_000));
        vm.prank(user);
        vm.expectRevert(ICovenRouter.PartialFill.selector);
        router.swap(_params(USDC, 1_000_000e6, hops, 1), user);
    }
    function test_minAmountOutIsCheckedAfterFees() public {
        uint256 amountIn = 750e18;
        (ICovenRouter.Hop[] memory hops, uint256 gross) = _quote(address(tokenA), USDC, amountIn);
        uint256 net = gross - _fee(gross, PLATFORM_FEE_BPS);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ICovenRouter.InsufficientOutput.selector, net, gross));
        router.swap(_params(address(tokenA), amountIn, hops, gross), user);
    }
    function test_rejectsInvalidParameters() public {
        ICovenRouter.Hop[] memory hops = _one(_v3(address(tokenA), 3000));
        ICovenRouter.SwapParams memory p = _params(USDC, 100e6, hops, 1);
        vm.startPrank(user);
        p.deadline = block.timestamp - 1;
        vm.expectRevert(ICovenRouter.Expired.selector);
        router.swap(p, user);
        p = _params(USDC, 100e6, hops, 0);
        vm.expectRevert(ICovenRouter.ZeroMinAmountOut.selector);
        router.swap(p, user);
        p = _params(USDC, 0, hops, 1);
        vm.expectRevert(ICovenRouter.ZeroAmount.selector);
        router.swap(p, user);
        p = _params(USDC, 100e6, new ICovenRouter.Hop[](0), 1);
        vm.expectRevert(ICovenRouter.InvalidPath.selector);
        router.swap(p, user);
        p = _params(USDC, 100e6, new ICovenRouter.Hop[](5), 1);
        vm.expectRevert(ICovenRouter.InvalidPath.selector);
        router.swap(p, user);
        p = _params(USDC, 100e6, _one(_v3(USDC, 3000)), 1);
        vm.expectRevert(ICovenRouter.InvalidPath.selector);
        router.swap(p, user);
        p = _params(USDC, 100e6, _one(ICovenRouter.Hop(ICovenRouter.Protocol.V3, address(tokenA), 3000, 60, address(0))), 1);
        vm.expectRevert(ICovenRouter.InvalidPath.selector);
        router.swap(p, user);
        p = _params(USDC, 100e6, hops, 1);
        p.integratorFeeBps = 10;
        vm.expectRevert(ICovenRouter.InvalidIntegratorFee.selector);
        router.swap(p, user);
        p.integrator = partner;
        p.integratorFeeBps = 301;
        vm.expectRevert(ICovenRouter.InvalidIntegratorFee.selector);
        router.swap(p, user);
        p.integrator = address(router);
        p.integratorFeeBps = 10;
        vm.expectRevert(ICovenRouter.InvalidIntegratorFee.selector);
        router.swap(p, user);
        p = _params(USDC, 100e6, hops, 1);
        vm.expectRevert(ICovenRouter.InvalidRecipient.selector);
        router.swap(p, address(0));
        vm.expectRevert(ICovenRouter.InvalidRecipient.selector);
        router.swap(p, address(router));
        vm.stopPrank();
    }
    function test_integratorWithoutFeeIsAllowed() public {
        (ICovenRouter.Hop[] memory hops, uint256 expected) =
            _quote(USDC, address(tokenA), 100e6 - _fee(100e6, PLATFORM_FEE_BPS));
        ICovenRouter.SwapParams memory p = _params(USDC, 100e6, hops, expected);
        p.integrator = partner;
        vm.prank(user);
        assertEq(router.swap(p, user), expected);
        assertEq(IERC20(USDC).balanceOf(partner), 0);
    }
    function test_swapAndBridgeBurnsExactNetOutput() public {
        uint256 amountIn = 750e18;
        (ICovenRouter.Hop[] memory hops, uint256 gross) = _quote(address(tokenA), USDC, amountIn);
        uint256 net = gross - _fee(gross, PLATFORM_FEE_BPS);
        bytes32 recipient = bytes32(uint256(uint160(user)));
        ICovenRouter.BridgeParams memory bridge = ICovenRouter.BridgeParams({
            destinationDomain: 6,
            mintRecipient: recipient,
            destinationCaller: bytes32(0),
            maxFee: 0,
            minFinalityThreshold: 2000,
            hookData: FORWARD_HOOK
        });
        vm.expectCall(
            TOKEN_MESSENGER,
            abi.encodeCall(
                ITokenMessengerV2.depositForBurnWithHook, (net, 6, recipient, USDC, bytes32(0), 0, 2000, FORWARD_HOOK)
            )
        );
        vm.recordLogs();
        vm.prank(user);
        uint256 bridged = router.swapAndBridge(_params(address(tokenA), amountIn, hops, net), bridge);
        assertEq(bridged, net);
        assertTrue(_emittedBy(TOKEN_MESSENGER, vm.getRecordedLogs()));
        assertEq(IERC20(USDC).allowance(address(router), TOKEN_MESSENGER), 0);
        _assertRouterEmpty();
    }
    function test_swapAndBridgeWithoutHookData() public {
        uint256 amountIn = 100e18;
        (ICovenRouter.Hop[] memory hops, uint256 gross) = _quote(address(tokenA), USDC, amountIn);
        uint256 net = gross - _fee(gross, PLATFORM_FEE_BPS);
        bytes32 recipient = bytes32(uint256(uint160(user)));
        ICovenRouter.BridgeParams memory bridge = ICovenRouter.BridgeParams(3, recipient, bytes32(0), 0, 2000, "");
        vm.expectCall(
            TOKEN_MESSENGER,
            abi.encodeCall(ITokenMessengerV2.depositForBurn, (net, 3, recipient, USDC, bytes32(0), 0, 2000))
        );
        vm.prank(user);
        assertEq(router.swapAndBridge(_params(address(tokenA), amountIn, hops, net), bridge), net);
        _assertRouterEmpty();
    }
    function test_swapAndBridgeValidation() public {
        bytes32 recipient = bytes32(uint256(uint160(user)));
        ICovenRouter.BridgeParams memory bridge = ICovenRouter.BridgeParams(6, recipient, bytes32(0), 0, 2000, "");
        ICovenRouter.SwapParams memory p = _params(USDC, 100e6, _one(_v3(address(tokenA), 3000)), 1);
        vm.startPrank(user);
        vm.expectRevert(ICovenRouter.BridgeRequiresUsdc.selector);
        router.swapAndBridge(p, bridge);
        bridge.destinationDomain = 26;
        vm.expectRevert(ICovenRouter.InvalidDestination.selector);
        router.swapAndBridge(p, bridge);
        bridge.destinationDomain = 6;
        bridge.mintRecipient = bytes32(0);
        vm.expectRevert(ICovenRouter.InvalidRecipient.selector);
        router.swapAndBridge(p, bridge);
        vm.stopPrank();
    }
    function test_guardianPausesAndOnlyOwnerUnpauses() public {
        ICovenRouter.SwapParams memory p = _params(USDC, 100e6, _one(_v3(address(tokenA), 3000)), 1);
        vm.prank(user);
        vm.expectRevert(ICovenRouter.Unauthorized.selector);
        router.pause();
        vm.prank(guardian);
        router.pause();
        vm.prank(user);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.swap(p, user);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        router.unpause();
        vm.prank(owner);
        router.unpause();
        vm.prank(user);
        assertGt(router.swap(p, user), 0);
    }
    function test_adminControls() public {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        router.setPlatformFee(10);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        router.setFeeRecipient(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        router.setHookAllowed(address(greedyHook), true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        router.addHookTemplate(address(hookOne), new uint16[](0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        router.sweep(IERC20(USDC), user, 1);
        vm.stopPrank();
        vm.startPrank(owner);
        vm.expectRevert(ICovenRouter.InvalidPlatformFee.selector);
        router.setPlatformFee(101);
        vm.expectRevert(ICovenRouter.InvalidFeeRecipient.selector);
        router.setFeeRecipient(address(0));
        vm.expectRevert(ICovenRouter.InvalidFeeRecipient.selector);
        router.setFeeRecipient(address(router));
        vm.expectRevert(ICovenRouter.InvalidGuardian.selector);
        router.setGuardian(address(0));
        vm.expectRevert(ICovenRouter.InvalidHook.selector);
        router.setHookAllowed(address(0), true);
        vm.expectRevert(ICovenRouter.OwnershipCannotBeRenounced.selector);
        router.renounceOwnership();
        router.setPlatformFee(0);
        vm.stopPrank();
        (ICovenRouter.Hop[] memory hops, uint256 expected) = _quote(USDC, address(tokenA), 100e6);
        vm.prank(user);
        assertEq(router.swap(_params(USDC, 100e6, hops, expected), user), expected);
        assertEq(IERC20(USDC).balanceOf(treasury), 0);
    }
    function test_ownershipTransferIsTwoStep() public {
        address next = makeAddr("next");
        vm.prank(owner);
        router.transferOwnership(next);
        assertEq(router.owner(), owner);
        vm.prank(next);
        router.acceptOwnership();
        assertEq(router.owner(), next);
    }
    function test_templateRegistrationValidation() public {
        uint16[] memory offsets = new uint16[](2);
        vm.startPrank(owner);
        vm.expectRevert(ICovenRouter.InvalidTemplate.selector);
        router.addHookTemplate(makeAddr("empty"), new uint16[](0));
        offsets[0] = 40;
        offsets[1] = 50;
        vm.expectRevert(ICovenRouter.InvalidTemplate.selector);
        router.addHookTemplate(address(hookOne), offsets);
        offsets[0] = 0;
        offsets[1] = SafeCast.toUint16(address(hookOne).code.length - 31);
        vm.expectRevert(ICovenRouter.InvalidTemplate.selector);
        router.addHookTemplate(address(hookOne), offsets);
        router.addHookTemplate(address(hookOne), new uint16[](0));
        vm.expectRevert(ICovenRouter.TemplateExists.selector);
        router.addHookTemplate(address(hookOne), new uint16[](0));
        vm.expectRevert(ICovenRouter.TemplateNotFound.selector);
        router.removeHookTemplate(bytes32(uint256(1)));
        vm.stopPrank();
        assertTrue(router.isHookAllowed(address(hookOne)));
        assertFalse(router.isHookAllowed(address(hookTwo)));
    }
    function test_templateLimit() public {
        vm.startPrank(owner);
        for (uint256 i; i < router.MAX_HOOK_TEMPLATES(); ++i) {
            uint16[] memory offsets = new uint16[](1);
            offsets[0] = SafeCast.toUint16(i);
            router.addHookTemplate(address(hookOne), offsets);
        }
        vm.expectRevert(ICovenRouter.TooManyTemplates.selector);
        router.addHookTemplate(address(hookTwo), new uint16[](0));
        vm.stopPrank();
    }
    function test_sweepRecoversStrayTokens() public {
        tokenA.mint(address(router), 5e18);
        vm.prank(owner);
        router.sweep(IERC20(address(tokenA)), treasury, 5e18);
        assertEq(tokenA.balanceOf(treasury), 5e18);
        _assertRouterEmpty();
    }
    function test_unlockCallbackOnlyFromPoolManager() public {
        vm.expectRevert(ICovenRouter.Unauthorized.selector);
        router.unlockCallback("");
    }
    function testFuzz_executionMatchesQuote(uint256 amountIn, bool buy) public {
        address tokenIn = buy ? USDC : address(tokenA);
        address tokenOut = buy ? address(tokenA) : USDC;
        amountIn = buy ? bound(amountIn, 1e6, 20_000e6) : bound(amountIn, 1e18, 20_000e18);
        uint256 swapIn = buy ? amountIn - _fee(amountIn, PLATFORM_FEE_BPS) : amountIn;
        (ICovenRouter.Hop[] memory hops, uint256 gross) = _quote(tokenIn, tokenOut, swapIn);
        uint256 expected = buy ? gross : gross - _fee(gross, PLATFORM_FEE_BPS);
        vm.prank(user);
        assertEq(router.swap(_params(tokenIn, amountIn, hops, expected), user), expected);
        _assertRouterEmpty();
    }
    function _emittedBy(address emitter, Vm.Log[] memory logs) internal pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter) return true;
        }
        return false;
    }
}
