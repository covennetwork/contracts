// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
abstract contract TestHookBase is IHooks {
    error NotImplemented();
    function beforeInitialize(address, PoolKey calldata, uint160) external pure virtual returns (bytes4) {
        revert NotImplemented();
    }
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure virtual returns (bytes4) {
        revert NotImplemented();
    }
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        virtual
        returns (bytes4)
    {
        revert NotImplemented();
    }
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure virtual returns (bytes4, BalanceDelta) {
        revert NotImplemented();
    }
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure virtual returns (bytes4) {
        revert NotImplemented();
    }
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure virtual returns (bytes4, BalanceDelta) {
        revert NotImplemented();
    }
    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        virtual
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert NotImplemented();
    }
    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        virtual
        returns (bytes4, int128)
    {
        revert NotImplemented();
    }
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        virtual
        returns (bytes4)
    {
        revert NotImplemented();
    }
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        virtual
        returns (bytes4)
    {
        revert NotImplemented();
    }
}
contract OutputFeeHook is TestHookBase {
    using CurrencyLibrary for Currency;
    IPoolManager public immutable manager;
    uint256 public immutable feeBps;
    constructor(IPoolManager manager_, uint256 feeBps_) {
        manager = manager_;
        feeBps = feeBps_;
    }
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        require(msg.sender == address(manager), "not manager");
        bool outputIs1 = params.zeroForOne == (params.amountSpecified < 0);
        (Currency output, int128 amount) = outputIs1 ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
        uint256 absolute = SafeCast.toUint256(amount < 0 ? -int256(amount) : int256(amount));
        uint256 fee = absolute * feeBps / 10_000;
        manager.mint(address(this), output.toId(), fee);
        return (IHooks.afterSwap.selector, SafeCast.toInt128(SafeCast.toInt256(fee)));
    }
}
contract GreedyHook is TestHookBase {
    using CurrencyLibrary for Currency;
    IPoolManager public immutable manager;
    constructor(IPoolManager manager_) {
        manager = manager_;
    }
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        bool outputIs1 = params.zeroForOne == (params.amountSpecified < 0);
        (Currency output, int128 amount) = outputIs1 ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
        uint256 absolute = SafeCast.toUint256(amount < 0 ? -int256(amount) : int256(amount));
        uint256 fee = absolute / 2;
        manager.mint(address(this), output.toId(), fee);
        return (IHooks.afterSwap.selector, SafeCast.toInt128(SafeCast.toInt256(fee)));
    }
}
