// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
interface IV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}
interface IV3Pool {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
    function token0() external view returns (address);
    function token1() external view returns (address);
}
/// @notice Deprecated: superseded by CovenProbe, which @covennetwork/arb trades through from 0.5.0.
contract CovenArb is IUnlockCallback, Ownable2Step, ReentrancyGuardTransient {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;
    struct Leg {
        bool isV4;
        address pool;
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint160 sqrtLimit;
        uint24 fee;
        bytes hookData;
    }
    struct Plan {
        Leg[] legs;
        address profitToken;
        uint256 minProfit;
        uint16 maxFeeBps;
    }
    IPoolManager public constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IV3Factory public constant V3_FACTORY = IV3Factory(0xf0db7b58379503491d857dB50AC9ece64c653918);
    uint256 public constant MAX_LEGS = 4;
    uint16 public constant MAX_FEE_BPS = 2000;
    uint16 private constant BPS = 10_000;
    uint16 public feeBps;
    address public feeRecipient;
    address private transient _expectedV3Pool;
    address private transient _expectedTokenIn;
    error NotPoolManager();
    error UnexpectedCallback();
    error WrongPool();
    error InvalidPlan();
    error ZeroMinProfit();
    error NoProfit();
    error ZeroLegOutput();
    error BelowMinProfit(uint256 net, uint256 minProfit);
    error InvalidFee();
    error FeeAbovePlanLimit(uint16 feeBps, uint16 maxFeeBps);
    error InvalidFeeRecipient();
    error OwnershipCannotBeRenounced();
    event Executed(address indexed caller, address indexed profitToken, uint256 profit, uint256 fee);
    event FeeUpdated(uint16 feeBps);
    event FeeRecipientUpdated(address indexed feeRecipient);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    constructor(address initialOwner, address initialFeeRecipient, uint16 initialFeeBps) Ownable(initialOwner) {
        _setFeeRecipient(initialFeeRecipient);
        _setFee(initialFeeBps);
    }
    function execute(Plan calldata plan) external nonReentrant returns (uint256 profit) {
        uint256 count = plan.legs.length;
        if (count == 0 || count > MAX_LEGS) revert InvalidPlan();
        if (plan.profitToken == address(0)) revert InvalidPlan();
        if (plan.minProfit == 0) revert ZeroMinProfit();
        bytes memory result = POOL_MANAGER.unlock(abi.encode(plan, msg.sender));
        profit = abi.decode(result, (uint256));
    }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (Plan memory plan, address caller) = abi.decode(data, (Plan, address));
        uint256 carry;
        for (uint256 i; i < plan.legs.length; ++i) {
            Leg memory leg = plan.legs[i];
            uint256 amountIn = i == 0 ? leg.amountIn : carry;
            carry = leg.isV4 ? _v4Leg(leg, amountIn) : _v3Leg(leg, amountIn);
        }
        Currency profitCurrency = Currency.wrap(plan.profitToken);
        int256 delta = POOL_MANAGER.currencyDelta(address(this), profitCurrency);
        if (delta <= 0) revert NoProfit();
        uint256 profit = SafeCast.toUint256(delta);
        uint16 currentFeeBps = feeBps;
        if (currentFeeBps > plan.maxFeeBps) revert FeeAbovePlanLimit(currentFeeBps, plan.maxFeeBps);
        uint256 fee = profit * currentFeeBps / BPS;
        uint256 net = profit - fee;
        if (net < plan.minProfit) revert BelowMinProfit(net, plan.minProfit);
        if (fee != 0) POOL_MANAGER.mint(feeRecipient, profitCurrency.toId(), fee);
        POOL_MANAGER.take(profitCurrency, caller, net);
        emit Executed(caller, plan.profitToken, net, fee);
        return abi.encode(net);
    }
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != _expectedV3Pool) revert UnexpectedCallback();
        int256 owedDelta = amount0Delta > 0 ? amount0Delta : amount1Delta;
        POOL_MANAGER.take(Currency.wrap(_expectedTokenIn), msg.sender, SafeCast.toUint256(owedDelta));
    }
    function setFee(uint16 newFeeBps) external onlyOwner {
        _setFee(newFeeBps);
    }
    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        _setFeeRecipient(newFeeRecipient);
    }
    function rescue(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidFeeRecipient();
        SafeERC20.safeTransfer(token, to, amount);
        emit Rescued(address(token), to, amount);
    }
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }
    function _v4Leg(Leg memory leg, uint256 amountIn) private returns (uint256 out) {
        BalanceDelta delta = POOL_MANAGER.swap(
            leg.key,
            IPoolManager.SwapParams({
                zeroForOne: leg.zeroForOne,
                amountSpecified: -SafeCast.toInt256(amountIn),
                sqrtPriceLimitX96: leg.sqrtLimit
            }),
            leg.hookData
        );
        int128 outDelta = leg.zeroForOne ? delta.amount1() : delta.amount0();
        if (outDelta <= 0) revert ZeroLegOutput();
        out = SafeCast.toUint256(int256(outDelta));
    }
    function _v3Leg(Leg memory leg, uint256 amountIn) private returns (uint256 out) {
        address t0 = IV3Pool(leg.pool).token0();
        address t1 = IV3Pool(leg.pool).token1();
        if (leg.pool != V3_FACTORY.getPool(t0, t1, leg.fee)) revert WrongPool();
        (address tokenIn, address tokenOut) = leg.zeroForOne ? (t0, t1) : (t1, t0);
        POOL_MANAGER.sync(Currency.wrap(tokenOut));
        _expectedV3Pool = leg.pool;
        _expectedTokenIn = tokenIn;
        IV3Pool(leg.pool).swap(address(POOL_MANAGER), leg.zeroForOne, SafeCast.toInt256(amountIn), leg.sqrtLimit, "");
        _expectedV3Pool = address(0);
        _expectedTokenIn = address(0);
        out = POOL_MANAGER.settle();
    }
    function _setFee(uint16 newFeeBps) private {
        if (newFeeBps > MAX_FEE_BPS) revert InvalidFee();
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }
    function _setFeeRecipient(address newFeeRecipient) private {
        if (newFeeRecipient == address(0) || newFeeRecipient == address(this)) revert InvalidFeeRecipient();
        feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(newFeeRecipient);
    }
}
