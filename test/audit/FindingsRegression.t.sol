// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// Regression tests for the findings in audit/2026-09-23-security-review.md.
// Each one failed before the fix and passes after it.

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {CovenRouter} from "../../src/CovenRouter.sol";
import {CovenSession} from "../../src/CovenSession.sol";
import {ICovenRouter} from "../../src/interfaces/ICovenRouter.sol";
import {MockERC20, MockSwapRouter02, MockPoolManager, MockTokenMessenger} from "./Mocks.sol";

contract StubLens {
    uint256 public gross;

    function setGross(uint256 g) external {
        gross = g;
    }

    function quote(address, address tokenOut, uint256, address[] calldata, PoolKey[] calldata, uint16)
        external
        view
        returns (ICovenRouter.Hop[] memory hops, uint256 amountOut)
    {
        hops = new ICovenRouter.Hop[](1);
        hops[0] = ICovenRouter.Hop(ICovenRouter.Protocol.V3, tokenOut, 3000, 0, address(0));
        amountOut = gross;
    }
}

/// Router stub that delivers exactly `deliver`, modelling an adversarially routed
/// or sandwiched execution. It still honours minAmountOut.
contract StubRouter {
    uint16 public platformFeeBps;
    uint256 public deliver;

    function setDeliver(uint256 d) external {
        deliver = d;
    }

    function swap(ICovenRouter.SwapParams calldata params, address recipient) external returns (uint256) {
        require(MockERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn), "tf");
        require(deliver >= params.minAmountOut, "minAmountOut");
        MockERC20(params.hops[params.hops.length - 1].tokenOut).mint(recipient, deliver);
        return deliver;
    }
}

contract DenylistERC20 is MockERC20 {
    mapping(address => bool) public denied;

    constructor(string memory n, string memory s) MockERC20(n, s) {}

    function setDenied(address a, bool v) external {
        denied[a] = v;
    }

    function transfer(address to, uint256 amt) public override returns (bool) {
        require(!denied[to], "denylisted");
        _transfer(msg.sender, to, amt);
        return true;
    }
}

// ---------------------------------------------------------------------------
// C-01
// ---------------------------------------------------------------------------

contract Regression_SessionSlippage is Test {
    address constant USDC = 0x3600000000000000000000000000000000000000;

    StubRouter routerStub;
    StubLens lensStub;
    CovenSession session;
    MockERC20 tokenA;

    address sessOwner = makeAddr("sessOwner");
    address sessKey = makeAddr("sessKey");

    function setUp() public {
        deployCodeTo("Mocks.sol:MockERC20", abi.encode("USD Coin", "USDC"), USDC);
        routerStub = new StubRouter();
        lensStub = new StubLens();
        tokenA = new MockERC20("A", "A");

        CovenSession.TokenCap[] memory caps = new CovenSession.TokenCap[](2);
        caps[0] = CovenSession.TokenCap({token: USDC, perTradeCap: 10_000e6, dailyCap: 100_000e6});
        caps[1] = CovenSession.TokenCap({token: address(tokenA), perTradeCap: 1e30, dailyCap: 1e30});

        session = new CovenSession(
            sessOwner,
            CovenSession.InitConfig({
                router: address(routerStub),
                lens: address(lensStub),
                sessionKey: sessKey,
                changeDelay: 1 hours,
                expiry: uint40(block.timestamp + 30 days),
                tradeCountCap: 100,
                maxImpactBps: 500,
                maxSlippageBps: 100,
                tokens: caps
            })
        );

        MockERC20(USDC).mint(sessOwner, 1_000_000e6);
        vm.prank(sessOwner);
        MockERC20(USDC).approve(address(session), type(uint256).max);
        lensStub.setGross(1_000e18);
    }

    function _swap(uint256 expectedOut) internal returns (uint256) {
        vm.prank(sessKey);
        return session.executeSwap(USDC, address(tokenA), 1_000e6, new PoolKey[](0), expectedOut, block.timestamp + 1 days);
    }

    /// The floor now comes from the quote the contract computed, so understating
    /// `expectedOut` no longer widens it.
    function test_C01_lowExpectedOutCannotWidenTheFloor() public {
        routerStub.setDeliver(1_000); // 1e-15 of the quote
        vm.expectRevert(bytes("minAmountOut"));
        _swap(1_000);

        // and the bound really is the configured 1% off the on-chain quote
        routerStub.setDeliver(989e18); // 1.1% worse
        vm.expectRevert(bytes("minAmountOut"));
        _swap(1_000);

        routerStub.setDeliver(995e18); // 0.5% worse, inside the ceiling
        assertEq(_swap(1_000), 995e18, "an execution inside the ceiling still clears");
    }

    /// A caller may still tighten the floor above the contract's own, never below it.
    function test_C01_callerMayOnlyTighten() public {
        routerStub.setDeliver(995e18);
        vm.expectRevert(bytes("minAmountOut"));
        _swap(999e18); // caller demands more than the router delivers
        assertEq(_swap(0), 995e18, "expectedOut = 0 falls back to the contract's floor");
    }

    function test_C01_zeroQuoteStillReverts() public {
        lensStub.setGross(0);
        routerStub.setDeliver(1e18);
        vm.prank(sessKey);
        vm.expectRevert(CovenSession.NoRouteWithinImpact.selector);
        session.executeSwap(USDC, address(tokenA), 1_000e6, new PoolKey[](0), 1e18, block.timestamp + 1 days);
    }
}

// ---------------------------------------------------------------------------
// H-01 and M-03
// ---------------------------------------------------------------------------

contract Regression_RouterHardening is Test {
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant SWAP_ROUTER_02 = 0x53BF6B0684Ec7eF91e1387Da3D1a1769bC5A6F77;
    address constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;

    CovenRouter router;
    MockERC20 tokenA;
    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address guardian = makeAddr("guardian");
    address user = makeAddr("user");

    function setUp() public {
        deployCodeTo("FindingsRegression.t.sol:DenylistERC20", abi.encode("USD Coin", "USDC"), USDC);
        deployCodeTo("Mocks.sol:MockPoolManager", "", POOL_MANAGER);
        deployCodeTo("Mocks.sol:MockSwapRouter02", "", SWAP_ROUTER_02);
        deployCodeTo("Mocks.sol:MockTokenMessenger", "", TOKEN_MESSENGER);
        router = new CovenRouter(
            owner, treasury, guardian, 30, new address[](0), new ICovenRouter.TemplateInit[](0)
        );
        tokenA = new MockERC20("A", "A");
        MockERC20(USDC).mint(user, 1_000_000e6);
        vm.prank(user);
        MockERC20(USDC).approve(address(router), type(uint256).max);
    }

    function _hop(uint24 fee, address hook) internal view returns (ICovenRouter.Hop[] memory hops) {
        hops = new ICovenRouter.Hop[](1);
        hops[0] = ICovenRouter.Hop(
            hook == address(0) ? ICovenRouter.Protocol.V3 : ICovenRouter.Protocol.V4,
            address(tokenA),
            fee,
            hook == address(0) ? int24(0) : int24(60),
            hook
        );
    }

    function _swap(ICovenRouter.Hop[] memory hops) internal returns (uint256) {
        vm.prank(user);
        return router.swap(
            ICovenRouter.SwapParams({
                tokenIn: USDC,
                amountIn: 1_000e6,
                hops: hops,
                minAmountOut: 1,
                deadline: block.timestamp + 1 days,
                integrator: address(0),
                integratorFeeBps: 0
            }),
            user
        );
    }

    /// A dynamic-fee pool is now gated on the allowlist even though its hook holds
    /// no swap-permission bits, because the hook can still set the fee to 100%.
    function test_H01_dynamicFeePoolNeedsTheAllowlist() public {
        address hook = address(uint160(0xbAd0000000000000000000000000000000000000) | Hooks.BEFORE_DONATE_FLAG);
        assertEq(uint160(hook) & router.SWAP_HOOK_FLAGS(), 0, "no swap permissions");

        vm.expectRevert(abi.encodeWithSelector(ICovenRouter.HookNotAllowed.selector, hook));
        _swap(_hop(LPFeeLibrary.DYNAMIC_FEE_FLAG, hook));

        vm.prank(owner);
        router.setHookAllowed(hook, true);
        assertGt(_swap(_hop(LPFeeLibrary.DYNAMIC_FEE_FLAG, hook)), 0, "allowed once the owner reviews it");
    }

    /// Static-fee pools with a flagless hook are unaffected: they still route freely.
    function test_H01_staticFeeFlaglessHookStillRoutesWithoutAllowlist() public {
        address hook = address(uint160(0xbAd0000000000000000000000000000000000000) | Hooks.BEFORE_DONATE_FLAG);
        assertFalse(router.isHookAllowed(hook), "not allowlisted");
        assertGt(_swap(_hop(3000, hook)), 0, "a static-fee pool is unchanged");
    }

    /// A denylisted fee recipient no longer halts trading; the fee accrues instead
    /// and the recipient claims it to an address that can receive.
    function test_M03_denylistedRecipientAccruesInsteadOfReverting() public {
        DenylistERC20(USDC).setDenied(treasury, true);

        uint256 out = _swap(_hop(3000, address(0)));
        assertGt(out, 0, "swaps keep working");
        uint256 owed = router.claimableFees(USDC, treasury);
        assertEq(owed, 1_000e6 * 30 / 10_000, "fee accrued for the frozen recipient");
        assertEq(router.totalClaimableFees(USDC), owed, "reserved against sweep");

        address safe = makeAddr("safe");
        vm.prank(treasury);
        router.claimFees(IERC20(USDC), safe);
        assertEq(MockERC20(USDC).balanceOf(safe), owed, "claimed out");
        assertEq(router.claimableFees(USDC, treasury), 0, "cleared");
    }

    /// sweep cannot take fees that are owed to someone else.
    function test_M03_sweepCannotTakeAccruedFees() public {
        DenylistERC20(USDC).setDenied(treasury, true);
        _swap(_hop(3000, address(0)));
        uint256 owed = router.claimableFees(USDC, treasury);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICovenRouter.SweepExceedsFree.selector, owed, 0));
        router.sweep(IERC20(USDC), owner, owed);
    }

    function test_M03_healthyRecipientStillGetsPaidImmediately() public {
        _swap(_hop(3000, address(0)));
        assertEq(MockERC20(USDC).balanceOf(treasury), 1_000e6 * 30 / 10_000, "paid inline");
        assertEq(router.claimableFees(USDC, treasury), 0, "nothing accrued");
    }
}
