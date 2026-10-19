// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
interface IV3StylePool2 {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
    function liquidity() external view returns (uint128);
}
interface IWrappedNative {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
/// @notice Arbitrage probe for chains whose gas token has a wrapped ERC-20 (ETH and WETH).
/// Anyone can call it: it checks each route against live pool state and trades only the ones
/// that pay, sizing on-chain. A route with no gap, or whose trade no longer pays, returns 0
/// instead of reverting, so a missed send costs little gas. Holds no inventory: every leg is
/// funded by PoolManager flash accounting and settled in the same unlock. The caller gets the
/// profit less `feeBps`, which goes to `feeRecipient` as PoolManager claims.
/// A route starts in any currency and ends in the same one, where native and wrapped count as
/// one: v4 pools may hold native ETH and v3-style pools WETH, and the probe converts between
/// them wherever a leg needs the other form.
contract CovenProbe2 is IUnlockCallback, Ownable2Step, ReentrancyGuardTransient {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    /// @dev v4: `key` is the pool. v3-style (Uniswap v3 and its forks, Slipstream clones):
    /// `pool`, `tokenIn` and `tokenOut` are. `feePips` is added to a v4 pool's live LP fee
    /// (hook fees) and is the whole fee of a v3-style pool; it is used only by the check
    /// and the sizing, never trusted for settlement.
    struct Leg {
        bool v4;
        bool zeroForOne;
        uint24 feePips;
        address pool;
        address tokenIn;
        address tokenOut;
        PoolKey key;
        bytes hookData;
    }
    /// @dev Optional precondition: skip the route unless word `word` of `target.staticcall(data)`
    /// is at least `min`.
    struct Gate {
        address target;
        bytes data;
        uint256 word;
        uint256 min;
    }
    /// @dev `amountIn` is the first leg's input; later legs spend all the contract is owed in
    /// their input currency (native and wrapped together). `sized`: a two-leg route whose first
    /// leg stops at the price where both pools meet, with `amountIn` as a cap. `firstAtPrice`:
    /// the first leg's price limit is next to its pool's current price, so in effect only a
    /// hook's own inventory fills it. `check`: skip the route unless the fee-adjusted prices
    /// around the cycle show a gap. Profit is in the first leg's input currency.
    struct Route {
        Leg[] legs;
        uint256 amountIn;
        uint256 minProfit;
        bool sized;
        bool firstAtPrice;
        bool check;
        Gate gate;
    }
    IPoolManager public immutable POOL_MANAGER;
    address public immutable WRAPPED_NATIVE;
    uint256 public constant MAX_LEGS = 4;
    uint256 private constant Q96 = 1 << 96;
    uint256 private constant Q192 = 1 << 192;
    uint16 public constant MAX_FEE_BPS = 2000;
    uint16 private constant BPS = 10_000;
    uint16 public feeBps;
    address public feeRecipient;
    address private transient _caller;
    address private transient _expectedPool;
    address private transient _expectedTokenIn;
    error NotSelf();
    error NotPoolManager();
    error UnexpectedCallback();
    error InvalidRoute();
    error ZeroLegInput();
    error ZeroLegOutput();
    error Unsettled();
    error BelowMinProfit(uint256 profit, uint256 minProfit);
    error InvalidAddress();
    error InvalidFee();
    error FeeAbovePlanLimit(uint16 feeBps, uint16 maxFeeBps);
    error OwnershipCannotBeRenounced();
    /// @dev `profit` is what the caller received, `fee` what went to the fee recipient, both in
    /// the route's start currency.
    event Executed(address indexed caller, uint256 indexed route, uint256 profit, uint256 fee);
    event FeeUpdated(uint16 feeBps);
    event FeeRecipientUpdated(address indexed feeRecipient);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    constructor(address initialOwner, address initialFeeRecipient, uint16 initialFeeBps, IPoolManager poolManager, address wrappedNative)
        Ownable(initialOwner)
    {
        if (address(poolManager) == address(0) || wrappedNative == address(0)) revert InvalidAddress();
        POOL_MANAGER = poolManager;
        WRAPPED_NATIVE = wrappedNative;
        _setFeeRecipient(initialFeeRecipient);
        _setFee(initialFeeBps);
    }
    receive() external payable {
        if (msg.sender != address(POOL_MANAGER) && msg.sender != WRAPPED_NATIVE) revert UnexpectedCallback();
    }
    /// @notice Check every route and trade the ones that pay; profits go to the caller, net of
    /// the fee. Never reverts for a route that has no gap or no longer pays: its profit is 0.
    /// Reverts if the fee is above `maxFeeBps`, so the owner cannot raise it on a caller.
    function probe(Route[] calldata routes, uint16 maxFeeBps) external nonReentrant returns (uint256[] memory profits) {
        if (feeBps > maxFeeBps) revert FeeAbovePlanLimit(feeBps, maxFeeBps);
        _caller = msg.sender;
        profits = new uint256[](routes.length);
        for (uint256 i; i < routes.length; ++i) {
            Route calldata r = routes[i];
            if (r.gate.target != address(0) && !_gateOpen(r.gate)) continue;
            if (r.check && !_hasGap(r)) continue;
            try this.run(r) returns (uint256 profit, uint256 fee) {
                profits[i] = profit;
                emit Executed(msg.sender, i, profit, fee);
            } catch {}
        }
    }
    /// @dev Self-call, so a failed trade reverts alone and `probe` carries on.
    function run(Route calldata r) external returns (uint256 profit, uint256 fee) {
        if (msg.sender != address(this)) revert NotSelf();
        uint256 n = r.legs.length;
        if (n == 0 || n > MAX_LEGS || r.amountIn == 0 || (r.sized && (n != 2 || r.firstAtPrice))) revert InvalidRoute();
        if (!_sameAsset(_currencyIn(r.legs[0]), _currencyOut(r.legs[n - 1]))) revert InvalidRoute();
        return abi.decode(POOL_MANAGER.unlock(abi.encode(r)), (uint256, uint256));
    }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        Route memory r = abi.decode(data, (Route));
        uint160 firstLimit;
        if (r.sized) firstLimit = _meetingLimit(r.legs[0], r.legs[1]);
        else if (r.firstAtPrice) firstLimit = _atPriceLimit(r.legs[0]);
        else firstLimit = _openLimit(r.legs[0].zeroForOne);
        for (uint256 i; i < r.legs.length; ++i) {
            Leg memory leg = r.legs[i];
            uint256 amountIn = i == 0 ? r.amountIn : _creditAs(_currencyIn(leg));
            if (amountIn == 0) revert ZeroLegInput();
            uint160 limit = i == 0 ? firstLimit : _openLimit(leg.zeroForOne);
            if (leg.v4) _v4Leg(leg, amountIn, limit);
            else _v3Leg(leg, amountIn, limit);
        }
        (uint256 profit, uint256 fee) = _settle(_currencyIn(r.legs[0]), r.minProfit);
        return abi.encode(profit, fee);
    }
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        _payV3(amount0Delta, amount1Delta);
    }
    function setFee(uint16 newFeeBps) external onlyOwner {
        _setFee(newFeeBps);
    }
    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        _setFeeRecipient(newFeeRecipient);
    }
    /// @notice Recover anything sent here by mistake. address(0) is native.
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert InvalidAddress();
        } else {
            SafeERC20.safeTransfer(IERC20(token), to, amount);
        }
        emit Rescued(token, to, amount);
    }
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }
    // ---- check and sizing ----
    /// @dev True if the product of the legs' fee-adjusted marginal rates exceeds 1. Rates are
    /// kept as square roots in Q96 so they multiply without overflow. Native and wrapped have
    /// the same decimals, so a route that changes form needs no rescaling.
    function _hasGap(Route calldata r) private view returns (bool) {
        uint256 product = Q96;
        for (uint256 i; i < r.legs.length; ++i) {
            Leg memory leg = r.legs[i];
            (uint160 sqrtPrice, uint24 fee) = _priceAndFee(leg);
            if (sqrtPrice == 0) return false;
            uint256 rate = leg.zeroForOne ? sqrtPrice : Q192 / sqrtPrice;
            product = Math.mulDiv(Math.mulDiv(product, rate, Q96), _sqrtGamma(fee), Q96);
        }
        return product > Q96;
    }
    /// @dev One step past the current price: a limit equal to it is rejected by the pool, and a
    /// hook that passes our limit to its own swap would revert.
    function _atPriceLimit(Leg memory leg) private view returns (uint160) {
        (uint160 sqrtPrice,) = _priceAndFee(leg);
        return leg.zeroForOne ? sqrtPrice - 1 : sqrtPrice + 1;
    }
    function _gateOpen(Gate calldata gate) private view returns (bool) {
        (bool ok, bytes memory ret) = gate.target.staticcall(gate.data);
        if (!ok || ret.length < (gate.word + 1) * 32) return false;
        uint256 value;
        uint256 offset = (gate.word + 1) * 32;
        assembly ("memory-safe") {
            value := mload(add(ret, offset))
        }
        return value >= gate.min;
    }
    /// @dev First-leg price limit for a sized two-leg route: the point where the two pools'
    /// fee-adjusted marginal prices meet, from each pool's in-range liquidity. With q the
    /// square root of the price of the middle token in the start currency, buying moves pool A
    /// from qA up and selling moves pool B from qB down; equal amounts give
    /// 1/q = (LA/qA + LB/qB) / (LA + LB). The pool stops at this limit and handles tick
    /// crossings itself; the profit check covers the approximation.
    function _meetingLimit(Leg memory a, Leg memory b) private view returns (uint160) {
        (uint160 sA, uint24 feeA) = _priceAndFee(a);
        (uint160 sB, uint24 feeB) = _priceAndFee(b);
        uint256 gA = _sqrtGamma(feeA);
        uint256 gB = _sqrtGamma(feeB);
        uint256 qA = Math.mulDiv(a.zeroForOne ? Q192 / sA : sA, Q96, gA);
        uint256 qB = Math.mulDiv(b.zeroForOne ? sB : Q192 / sB, gB, Q96);
        if (qB <= qA) return sA; // no gap: a limit at the current price makes the swap revert
        uint256 lA = _liquidity(a);
        uint256 lB = _liquidity(b);
        if (lA == 0 || lB == 0) return sA; // nothing in range to size against: skip
        uint256 lSum = lA + lB;
        uint256 inv = Math.mulDiv(lA, Q192 / qA, lSum) + Math.mulDiv(lB, Q192 / qB, lSum);
        uint256 q = Math.mulDiv(Q192 / inv, gA, Q96); // back to pool A's unadjusted price
        uint256 limit = a.zeroForOne ? Q192 / q : q;
        if (limit <= TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE + 1;
        if (limit >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return uint160(limit);
    }
    function _priceAndFee(Leg memory leg) private view returns (uint160 sqrtPrice, uint24 fee) {
        if (leg.v4) {
            uint24 lpFee;
            (sqrtPrice,,, lpFee) = POOL_MANAGER.getSlot0(leg.key.toId());
            fee = lpFee + leg.feePips;
        } else {
            sqrtPrice = _v3Price(leg.pool);
            fee = leg.feePips;
        }
    }
    /// @dev Every v3-style slot0 variant returns the price first.
    function _v3Price(address pool) private view returns (uint160) {
        (bool ok, bytes memory ret) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        if (!ok || ret.length < 32) return 0;
        return uint160(uint256(bytes32(ret)));
    }
    function _liquidity(Leg memory leg) private view returns (uint256) {
        return leg.v4 ? POOL_MANAGER.getLiquidity(leg.key.toId()) : IV3StylePool2(leg.pool).liquidity();
    }
    /// @dev sqrt(1 - fee) in Q96.
    function _sqrtGamma(uint24 fee) private pure returns (uint256) {
        if (fee >= 1e6) return 0;
        return Math.sqrt(Math.mulDiv(1e6 - fee, Q192, 1e6));
    }
    function _openLimit(bool zeroForOne) private pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }
    // ---- execution ----
    function _v4Leg(Leg memory leg, uint256 amountIn, uint160 limit) private {
        BalanceDelta delta = POOL_MANAGER.swap(
            leg.key,
            IPoolManager.SwapParams({zeroForOne: leg.zeroForOne, amountSpecified: -SafeCast.toInt256(amountIn), sqrtPriceLimitX96: limit}),
            leg.hookData
        );
        if ((leg.zeroForOne ? delta.amount1() : delta.amount0()) <= 0) revert ZeroLegOutput();
    }
    /// @dev The pool sends its output to the PoolManager (sync + settle credits it to us) and
    /// is paid in its callback with a `take` from the PoolManager.
    function _v3Leg(Leg memory leg, uint256 amountIn, uint160 limit) private {
        POOL_MANAGER.sync(Currency.wrap(leg.tokenOut));
        _expectedPool = leg.pool;
        _expectedTokenIn = leg.tokenIn;
        IV3StylePool2(leg.pool).swap(address(POOL_MANAGER), leg.zeroForOne, SafeCast.toInt256(amountIn), limit, "");
        _expectedPool = address(0);
        _expectedTokenIn = address(0);
        if (POOL_MANAGER.settle() == 0) revert ZeroLegOutput();
    }
    function _payV3(int256 amount0Delta, int256 amount1Delta) private {
        if (msg.sender != _expectedPool) revert UnexpectedCallback();
        int256 owed = amount0Delta > 0 ? amount0Delta : amount1Delta;
        POOL_MANAGER.take(Currency.wrap(_expectedTokenIn), msg.sender, SafeCast.toUint256(owed));
    }
    /// @dev Square the start currency's account, converting from its native or wrapped twin if
    /// the route ended in the other form, then pay the caller the profit less the fee, and the
    /// fee recipient the fee as PoolManager claims. Profit stays in the form it ended in.
    function _settle(address start, uint256 minProfit) private returns (uint256 profit, uint256 fee) {
        int256 d = POOL_MANAGER.currencyDelta(address(this), Currency.wrap(start));
        if (d < 0) {
            if (!_hasTwin(start)) revert Unsettled();
            address twin = _twin(start);
            uint256 owed = SafeCast.toUint256(-d);
            if (_credit(twin) < owed) revert Unsettled();
            _convert(twin, owed);
        }
        address caller = _caller;
        uint16 bps = feeBps;
        (uint256 p0, uint256 f0) = _payout(start, caller, bps);
        uint256 p1;
        uint256 f1;
        if (_hasTwin(start)) (p1, f1) = _payout(_twin(start), caller, bps);
        profit = p0 + p1;
        fee = f0 + f1;
        if (profit < minProfit) revert BelowMinProfit(profit, minProfit);
    }
    function _payout(address currency, address to, uint16 bps) private returns (uint256 net, uint256 fee) {
        uint256 gross = _credit(currency);
        if (gross == 0) return (0, 0);
        fee = gross * bps / BPS;
        net = gross - fee;
        Currency c = Currency.wrap(currency);
        if (fee != 0) POOL_MANAGER.mint(feeRecipient, c.toId(), fee);
        if (net != 0) POOL_MANAGER.take(c, to, net);
    }
    /// @dev Turn `amount` of credit in `from` (native or wrapped) into credit in its twin.
    function _convert(address from, uint256 amount) private {
        POOL_MANAGER.take(Currency.wrap(from), address(this), amount);
        if (from == address(0)) {
            IWrappedNative(WRAPPED_NATIVE).deposit{value: amount}();
            POOL_MANAGER.sync(Currency.wrap(WRAPPED_NATIVE));
            SafeERC20.safeTransfer(IERC20(WRAPPED_NATIVE), address(POOL_MANAGER), amount);
            POOL_MANAGER.settle();
        } else {
            IWrappedNative(WRAPPED_NATIVE).withdraw(amount);
            POOL_MANAGER.sync(Currency.wrap(address(0)));
            POOL_MANAGER.settle{value: amount}();
        }
    }
    /// @dev Credit available to spend as `currency`: converts the twin's whole credit over
    /// first, so a leg that needs WETH can follow a leg that paid out native ETH.
    function _creditAs(address currency) private returns (uint256) {
        if (_hasTwin(currency)) {
            address twin = _twin(currency);
            uint256 other = _credit(twin);
            if (other != 0) _convert(twin, other);
        }
        return _credit(currency);
    }
    function _hasTwin(address currency) private view returns (bool) {
        return currency == address(0) || currency == WRAPPED_NATIVE;
    }
    /// @dev Only meaningful when `_hasTwin(currency)`.
    function _twin(address currency) private view returns (address) {
        return currency == address(0) ? WRAPPED_NATIVE : address(0);
    }
    function _sameAsset(address a, address b) private view returns (bool) {
        return a == b || (_hasTwin(a) && _hasTwin(b));
    }
    function _credit(address currency) private view returns (uint256) {
        int256 d = POOL_MANAGER.currencyDelta(address(this), Currency.wrap(currency));
        return d > 0 ? uint256(d) : 0;
    }
    function _currencyIn(Leg memory leg) private pure returns (address) {
        if (!leg.v4) return leg.tokenIn;
        return Currency.unwrap(leg.zeroForOne ? leg.key.currency0 : leg.key.currency1);
    }
    function _currencyOut(Leg memory leg) private pure returns (address) {
        if (!leg.v4) return leg.tokenOut;
        return Currency.unwrap(leg.zeroForOne ? leg.key.currency1 : leg.key.currency0);
    }
    function _setFee(uint16 newFeeBps) private {
        if (newFeeBps > MAX_FEE_BPS) revert InvalidFee();
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }
    function _setFeeRecipient(address newFeeRecipient) private {
        if (newFeeRecipient == address(0) || newFeeRecipient == address(this)) revert InvalidAddress();
        feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(newFeeRecipient);
    }
}
