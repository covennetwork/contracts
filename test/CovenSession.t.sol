// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ICovenRouter} from "../src/interfaces/ICovenRouter.sol";
import {Fixture} from "./utils/Fixture.sol";
import {CovenSession} from "../src/CovenSession.sol";

contract CovenSessionTest is Fixture {
    CovenSession internal session;
    address internal sessOwner = makeAddr("sessOwner");
    address internal sessKey = makeAddr("sessKey");
    uint256 internal constant DELAY = 1 hours;

    function setUp() public override {
        super.setUp();
        session = _deploySession(1_000e6, 5_000e6, 1_000_000e18, 5_000_000e18, 10);
        vm.deal(sessOwner, 100_000_000e18);
        tokenA.mint(sessOwner, 100_000_000e18);
        vm.startPrank(sessOwner);
        IERC20(USDC).approve(address(session), type(uint256).max);
        tokenA.approve(address(session), type(uint256).max);
        vm.stopPrank();
    }

    function _deploySession(uint256 usdcPerTrade, uint256 usdcDaily, uint256 tokPerTrade, uint256 tokDaily, uint32 count)
        internal
        returns (CovenSession s)
    {
        CovenSession.TokenCap[] memory caps = new CovenSession.TokenCap[](2);
        caps[0] = CovenSession.TokenCap({token: USDC, perTradeCap: usdcPerTrade, dailyCap: usdcDaily});
        caps[1] = CovenSession.TokenCap({token: address(tokenA), perTradeCap: tokPerTrade, dailyCap: tokDaily});
        s = new CovenSession(
            sessOwner,
            CovenSession.InitConfig({
                router: address(router),
                lens: address(lens),
                sessionKey: sessKey,
                changeDelay: DELAY,
                expiry: uint40(block.timestamp + 30 days),
                tradeCountCap: count,
                maxImpactBps: 500,
                maxSlippageBps: 100,
                tokens: caps
            })
        );
    }

    function _noExtras() internal pure returns (PoolKey[] memory) {
        return new PoolKey[](0);
    }

    function _preview(CovenSession s, address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256) {
        (uint256 expectedOut,) = s.previewSwap(tokenIn, tokenOut, amountIn, _noExtras());
        return expectedOut;
    }

    function _buy(CovenSession s, uint256 amountIn) internal returns (uint256) {
        uint256 expectedOut = _preview(s, USDC, address(tokenA), amountIn);
        vm.prank(sessKey);
        return s.executeSwap(USDC, address(tokenA), amountIn, _noExtras(), expectedOut, block.timestamp + 1 days);
    }

    function _sell(CovenSession s, uint256 amountIn) internal returns (uint256) {
        uint256 expectedOut = _preview(s, address(tokenA), USDC, amountIn);
        vm.prank(sessKey);
        return s.executeSwap(address(tokenA), USDC, amountIn, _noExtras(), expectedOut, block.timestamp + 1 days);
    }

    function test_constructorRejectsShortDelay() public {
        CovenSession.TokenCap[] memory caps = new CovenSession.TokenCap[](1);
        caps[0] = CovenSession.TokenCap({token: USDC, perTradeCap: 1_000e6, dailyCap: 1_000e6});
        vm.expectRevert(CovenSession.InvalidConfig.selector);
        new CovenSession(
            sessOwner,
            CovenSession.InitConfig({
                router: address(router),
                lens: address(lens),
                sessionKey: sessKey,
                changeDelay: 59 minutes,
                expiry: uint40(block.timestamp + 30 days),
                tradeCountCap: 10,
                maxImpactBps: 500,
                maxSlippageBps: 100,
                tokens: caps
            })
        );
    }

    function test_happyPathBuyProceedsToOwner() public {
        uint256 ownerTokenBefore = tokenA.balanceOf(sessOwner);
        uint256 out = _buy(session, 100e6);
        assertGt(out, 0, "no output");
        assertEq(tokenA.balanceOf(sessOwner) - ownerTokenBefore, out, "proceeds to owner");
        assertEq(IERC20(USDC).balanceOf(address(session)), 0, "session holds usdc");
        assertEq(tokenA.balanceOf(address(session)), 0, "session holds token");
    }

    function test_happyPathSellProceedsToOwner() public {
        uint256 ownerUsdcBefore = IERC20(USDC).balanceOf(sessOwner);
        uint256 out = _sell(session, 100e18);
        assertGt(out, 0, "no output");
        assertEq(IERC20(USDC).balanceOf(sessOwner) - ownerUsdcBefore, out, "proceeds to owner");
        assertEq(tokenA.balanceOf(address(session)), 0, "session holds token");
    }

    function test_buyPerTradeCapEnforcedInUsdc() public {
        uint256 expectedOut = _preview(session, USDC, address(tokenA), 1_001e6);
        vm.prank(sessKey);
        vm.expectRevert(abi.encodeWithSelector(CovenSession.PerTradeCapExceeded.selector, USDC, uint256(1_001e6), uint256(1_000e6)));
        session.executeSwap(USDC, address(tokenA), 1_001e6, _noExtras(), expectedOut, block.timestamp + 1 days);
    }

    function test_sellCappedInTokenUnitsNotUsdcReturned() public {
        CovenSession s = _deploySession(1_000_000e6, 1_000_000e6, 50e18, 1_000e18, 100);
        vm.startPrank(sessOwner);
        tokenA.approve(address(s), type(uint256).max);
        IERC20(USDC).approve(address(s), type(uint256).max);
        vm.stopPrank();
        uint256 expectedOut = _preview(s, address(tokenA), USDC, 100e18);
        vm.prank(sessKey);
        vm.expectRevert(abi.encodeWithSelector(CovenSession.PerTradeCapExceeded.selector, address(tokenA), uint256(100e18), uint256(50e18)));
        s.executeSwap(address(tokenA), USDC, 100e18, _noExtras(), expectedOut, block.timestamp + 1 days);
        assertGt(_sell(s, 40e18), 0, "a sell within the token cap is allowed");
    }

    function test_dailyCapEnforced() public {
        for (uint256 i; i < 5; ++i) {
            _buy(session, 1_000e6);
        }
        uint256 expectedOut = _preview(session, USDC, address(tokenA), 1e6);
        vm.prank(sessKey);
        vm.expectRevert(abi.encodeWithSelector(CovenSession.DailyCapExceeded.selector, USDC, uint256(5_001e6), uint256(5_000e6)));
        session.executeSwap(USDC, address(tokenA), 1e6, _noExtras(), expectedOut, block.timestamp + 1 days);
    }

    function test_dailyCapWindowRollsOff() public {
        for (uint256 i; i < 5; ++i) {
            _buy(session, 1_000e6);
        }
        vm.warp(block.timestamp + 1 days + 1);
        assertGt(_buy(session, 1_000e6), 0, "should succeed after window");
    }

    function test_tradeCountCapEnforced() public {
        CovenSession s = _deploySession(1_000e6, 1_000_000e6, 1_000_000e18, 1_000_000e18, 2);
        vm.startPrank(sessOwner);
        IERC20(USDC).approve(address(s), type(uint256).max);
        vm.stopPrank();
        _buy(s, 10e6);
        _buy(s, 10e6);
        uint256 expectedOut = _preview(s, USDC, address(tokenA), 10e6);
        vm.prank(sessKey);
        vm.expectRevert(abi.encodeWithSelector(CovenSession.TradeCountCapExceeded.selector, uint256(3), uint256(2)));
        s.executeSwap(USDC, address(tokenA), 10e6, _noExtras(), expectedOut, block.timestamp + 1 days);
    }

    function test_expiryEnforced() public {
        vm.warp(block.timestamp + 31 days);
        vm.prank(sessKey);
        vm.expectRevert(CovenSession.SessionExpired.selector);
        session.executeSwap(USDC, address(tokenA), 100e6, _noExtras(), 1, block.timestamp + 1 days);
    }

    function test_allowlistEnforced() public {
        vm.prank(sessKey);
        vm.expectRevert(abi.encodeWithSelector(CovenSession.TokenNotAllowed.selector, address(tokenB)));
        session.executeSwap(USDC, address(tokenB), 100e6, _noExtras(), 1, block.timestamp + 1 days);
    }

    function test_priceImpactEnforced() public {
        CovenSession s = _deploySession(1_000_000e6, 1_000_000e6, 1_000_000e18, 1_000_000e18, 100);
        vm.startPrank(sessOwner);
        IERC20(USDC).approve(address(s), type(uint256).max);
        vm.stopPrank();
        vm.prank(sessOwner);
        s.setMaxImpactBps(1);
        vm.prank(sessKey);
        vm.expectRevert(CovenSession.NoRouteWithinImpact.selector);
        s.executeSwap(USDC, address(tokenA), 100_000e6, _noExtras(), 1, block.timestamp + 1 days);
    }

    function test_slippageAnchoredToSuppliedExpectedOut() public {
        uint256 honest = _preview(session, USDC, address(tokenA), 100e6);
        assertGt(_buy(session, 100e6), 0, "honest expectedOut passes");
        vm.prank(sessKey);
        vm.expectRevert();
        session.executeSwap(USDC, address(tokenA), 100e6, _noExtras(), honest * 2, block.timestamp + 1 days);
    }

    function test_sessionKeyCannotWidenLimits() public {
        vm.prank(sessKey);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, sessKey));
        session.setTokenCaps(USDC, 1_000_000e6, 1_000_000e6);
        vm.prank(sessKey);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, sessKey));
        session.setTradeCountCap(1000);
    }

    function test_limitIncreaseDelayedDecreaseImmediate() public {
        vm.prank(sessOwner);
        session.setTokenCaps(USDC, 2_000e6, 5_000e6);
        assertEq(session.perTradeCap(USDC), 1_000e6, "increase must not be immediate");
        uint256 e1 = _preview(session, USDC, address(tokenA), 1_500e6);
        vm.prank(sessKey);
        vm.expectRevert(abi.encodeWithSelector(CovenSession.PerTradeCapExceeded.selector, USDC, uint256(1_500e6), uint256(1_000e6)));
        session.executeSwap(USDC, address(tokenA), 1_500e6, _noExtras(), e1, block.timestamp + 1 days);
        vm.warp(block.timestamp + DELAY);
        assertEq(session.perTradeCap(USDC), 2_000e6, "increase effective after delay");
        assertGt(_buy(session, 1_500e6), 0, "1500 now allowed");
        vm.prank(sessOwner);
        session.setTokenCaps(USDC, 500e6, 5_000e6);
        assertEq(session.perTradeCap(USDC), 500e6, "decrease immediate");
        uint256 e2 = _preview(session, USDC, address(tokenA), 600e6);
        vm.prank(sessKey);
        vm.expectRevert(abi.encodeWithSelector(CovenSession.PerTradeCapExceeded.selector, USDC, uint256(600e6), uint256(500e6)));
        session.executeSwap(USDC, address(tokenA), 600e6, _noExtras(), e2, block.timestamp + 1 days);
    }

    function test_allowlistAddDelayedRevokeImmediate() public {
        vm.prank(sessOwner);
        session.setTokenCaps(address(tokenB), 100e18, 1_000e18);
        assertFalse(session.isAllowed(address(tokenB)), "add not immediate");
        vm.warp(block.timestamp + DELAY);
        assertTrue(session.isAllowed(address(tokenB)), "add effective after delay");
        vm.prank(sessOwner);
        session.revokeToken(address(tokenB));
        assertFalse(session.isAllowed(address(tokenB)), "revoke immediate");
    }

    function test_revokeImmediate() public {
        vm.prank(sessOwner);
        session.revoke();
        vm.prank(sessKey);
        vm.expectRevert(CovenSession.Revoked.selector);
        session.executeSwap(USDC, address(tokenA), 100e6, _noExtras(), 1, block.timestamp + 1 days);
    }

    function test_sessionKeyRotationDelayedDisableImmediate() public {
        address newKey = makeAddr("newKey");
        vm.prank(sessOwner);
        session.setSessionKey(newKey);
        uint256 e = _preview(session, USDC, address(tokenA), 100e6);
        vm.prank(newKey);
        vm.expectRevert(CovenSession.NotSessionKey.selector);
        session.executeSwap(USDC, address(tokenA), 100e6, _noExtras(), e, block.timestamp + 1 days);
        vm.warp(block.timestamp + DELAY);
        uint256 e2 = _preview(session, USDC, address(tokenA), 100e6);
        vm.prank(newKey);
        assertGt(session.executeSwap(USDC, address(tokenA), 100e6, _noExtras(), e2, block.timestamp + 1 days), 0, "new key active");
        vm.prank(sessOwner);
        session.setSessionKey(address(0));
        vm.prank(newKey);
        vm.expectRevert(CovenSession.NotSessionKey.selector);
        session.executeSwap(USDC, address(tokenA), 100e6, _noExtras(), e2, block.timestamp + 1 days);
    }
}
