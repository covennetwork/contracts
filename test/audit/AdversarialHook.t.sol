// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Fixture} from "../utils/Fixture.sol";
import {TestHookBase} from "../utils/TestHooks.sol";
import {TestToken} from "../utils/TestToken.sol";
import {ICovenRouter} from "../../src/interfaces/ICovenRouter.sol";

/// A hook that is BENIGN when called by the V4Quoter (quote time) but GREEDY when
/// called by anyone else (real execution). Models a hook that hides its theft from
/// the pricing path to fool the lens. The router's minAmountOut must still protect users.
contract TwoFacedHook is TestHookBase {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable manager;
    address constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        // Quote path: behave honestly so the lens sees a great price.
        if (sender == V4_QUOTER) return (IHooks.afterSwap.selector, int128(0));

        // Execution path: steal half the output.
        bool outputIs1 = params.zeroForOne == (params.amountSpecified < 0);
        (Currency output, int128 amount) = outputIs1 ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
        uint256 absolute = SafeCast.toUint256(amount < 0 ? -int256(amount) : int256(amount));
        uint256 fee = absolute / 2;
        manager.mint(address(this), output.toId(), fee);
        return (IHooks.afterSwap.selector, SafeCast.toInt128(SafeCast.toInt256(fee)));
    }
}

contract AdversarialHookTest is Fixture {
    TwoFacedHook internal twoFaced;
    TestToken internal tokenG;
    PoolKey internal twoFacedKey;

    function setUp() public override {
        super.setUp();
        tokenG = _token("G");
        twoFaced = TwoFacedHook(_deployHook("AdversarialHook.t.sol:TwoFacedHook", abi.encode(POOL_MANAGER), 0xF00D));
        twoFacedKey = _poolKey(address(tokenG), 10_000, 200, address(twoFaced));
        _v4FullRange(twoFacedKey, 1e18);
    }

    function _extrasG() internal view returns (PoolKey[] memory keys) {
        keys = new PoolKey[](1);
        keys[0] = twoFacedKey;
    }

    /// The lens gets a benign (full) quote; the hook then steals 50% at execution.
    /// A user who trusts the quote (minAmountOut == quoted) is fully protected: the
    /// swap REVERTS rather than delivering the stolen amount. A user with a loose
    /// tolerance receives less, but never less than the minAmountOut they signed.
    function test_quoteTimeDeceptiveHookIsBoundedByMinAmountOut() public {
        vm.prank(owner);
        router.setHookAllowed(address(twoFaced), true);

        uint256 amountIn = 100e6;
        uint256 swapIn = amountIn - _fee(amountIn, PLATFORM_FEE_BPS);

        address[] memory noConnectors = new address[](0);
        (ICovenRouter.Hop[] memory hops, uint256 quoted) =
            lens.quote(USDC, address(tokenG), swapIn, noConnectors, _extrasG(), IMPACT_BPS);

        // Lens was fooled: it routed through the two-faced hook and quoted the full amount.
        assertEq(hops.length, 1, "direct route");
        assertEq(hops[0].hooks, address(twoFaced), "routed via two-faced hook");
        assertGt(quoted, 0, "benign quote");

        // A user trusting the quote is protected — execution reverts, no theft.
        vm.prank(user);
        vm.expectRevert();
        router.swap(_params(USDC, amountIn, hops, quoted), user);

        // With a deliberately loose floor the swap can go through, but the user still
        // never receives less than the minAmountOut they authorized.
        uint256 looseFloor = quoted / 4;
        uint256 beforeBal = tokenG.balanceOf(user);
        vm.prank(user);
        uint256 out = router.swap(_params(USDC, amountIn, hops, looseFloor), user);
        assertGe(out, looseFloor, "never below signed floor");
        assertEq(tokenG.balanceOf(user) - beforeBal, out, "user received exactly out");
        assertLt(out, quoted, "hook did take a cut at execution");
        _assertRouterEmpty();
    }
}
