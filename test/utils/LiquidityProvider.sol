// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
contract LiquidityProvider is IUnlockCallback {
    IPoolManager public immutable manager;
    constructor(IPoolManager manager_) {
        manager = manager_;
    }
    function addLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liquidity) external {
        manager.unlock(abi.encode(key, tickLower, tickUpper, liquidity));
    }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liquidity) =
            abi.decode(data, (PoolKey, int24, int24, uint256));
        (BalanceDelta delta,) = manager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: SafeCast.toInt256(liquidity),
                salt: bytes32(0)
            }),
            ""
        );
        _pay(key.currency0, delta.amount0());
        _pay(key.currency1, delta.amount1());
        return "";
    }
    function _pay(Currency currency, int128 amount) private {
        if (amount >= 0) return;
        manager.sync(currency);
        require(IERC20(Currency.unwrap(currency)).transfer(address(manager), SafeCast.toUint256(-int256(amount))), "transfer");
        manager.settle();
    }
}
