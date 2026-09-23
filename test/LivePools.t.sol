// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ICovenRouter} from "../src/interfaces/ICovenRouter.sol";
import {CovenRouter} from "../src/CovenRouter.sol";
import {CovenLens} from "../src/CovenLens.sol";
import {ICovenRouter} from "../src/interfaces/ICovenRouter.sol";
import {IV4Quoter} from "../src/interfaces/external/IV4Quoter.sol";
import {IQuoterV2} from "./utils/Fixture.sol";
contract LivePoolsTest is Test {
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    address internal constant EURC = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;
    IQuoterV2 internal constant QUOTER_V2 = IQuoterV2(0x7DfD4F31be6814D2906BDE155c3e1B146EAc1468);
    IV4Quoter internal constant V4_QUOTER = IV4Quoter(0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94);
    CovenRouter internal router;
    CovenLens internal lens;
    address internal user = makeAddr("user");
    function setUp() public {
        vm.createSelectFork("arc");
        address owner = makeAddr("owner");
        router = new CovenRouter(owner, makeAddr("treasury"), owner, 0, new address[](0), new ICovenRouter.TemplateInit[](0));
        lens = new CovenLens(router);
        vm.deal(user, 1_000e18);
        vm.prank(user);
        IERC20(USDC).approve(address(router), type(uint256).max);
    }
    function test_usdcToEurcOnLivePools() public {
        uint256[3] memory amounts = [uint256(1e6), 25e6, 250e6];
        uint256 executed;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 amountIn = amounts[i];
            (ICovenRouter.Hop[] memory hops, uint256 quoted) =
                lens.quote(USDC, EURC, amountIn, new address[](0), new PoolKey[](0), 500);
            if (quoted == 0) continue;
            assertEq(hops.length, 1);
            assertEq(quoted, _reference(hops[0], amountIn));
            uint256 before = IERC20(EURC).balanceOf(user);
            ICovenRouter.SwapParams memory p = ICovenRouter.SwapParams({
                tokenIn: USDC,
                amountIn: amountIn,
                hops: hops,
                minAmountOut: quoted,
                deadline: block.timestamp,
                integrator: address(0),
                integratorFeeBps: 0
            });
            vm.prank(user);
            assertEq(router.swap(p, user), quoted);
            assertEq(IERC20(EURC).balanceOf(user) - before, quoted);
            ++executed;
        }
        assertGt(executed, 0);
    }
    function _reference(ICovenRouter.Hop memory hop, uint256 amountIn) internal returns (uint256 out) {
        if (hop.protocol == ICovenRouter.Protocol.V3) {
            (out,,,) = QUOTER_V2.quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams(USDC, EURC, amountIn, hop.fee, 0)
            );
        } else {
            (address t0, address t1) = USDC < EURC ? (USDC, EURC) : (EURC, USDC);
            PoolKey memory key = PoolKey(Currency.wrap(t0), Currency.wrap(t1), hop.fee, hop.tickSpacing, IHooks(hop.hooks));
            (out,) = V4_QUOTER.quoteExactInputSingle(
                IV4Quoter.QuoteExactSingleParams(key, USDC < EURC, SafeCast.toUint128(amountIn), "")
            );
        }
    }
}
