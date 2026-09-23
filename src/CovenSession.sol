// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ICovenRouter} from "./interfaces/ICovenRouter.sol";
interface ICovenLens {
    function quote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address[] calldata connectors,
        PoolKey[] calldata extraPools,
        uint16 maxImpactBps
    ) external returns (ICovenRouter.Hop[] memory hops, uint256 amountOut);
}
contract CovenSession is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    struct Gate {
        uint256 cur;
        uint256 pend;
        uint40 pendAt;
    }
    struct Window {
        uint40 start;
        uint256 spent;
    }
    struct TokenCap {
        address token;
        uint256 perTradeCap;
        uint256 dailyCap;
    }
    struct InitConfig {
        address router;
        address lens;
        address sessionKey;
        uint256 changeDelay;
        uint40 expiry;
        uint32 tradeCountCap;
        uint16 maxImpactBps;
        uint16 maxSlippageBps;
        TokenCap[] tokens;
    }
    address public constant USDC = 0x3600000000000000000000000000000000000000;
    address public constant EURC = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;
    uint256 internal constant EXPIRY = 0;
    uint256 internal constant COUNT = 1;
    uint256 internal constant IMPACT = 2;
    uint256 internal constant SLIPPAGE = 3;
    uint256 internal constant PER_TRADE = 4;
    uint256 internal constant DAILY = 5;
    uint16 internal constant BPS = 10_000;
    uint256 internal constant WINDOW = 1 days;
    uint256 public constant MIN_CHANGE_DELAY = 1 hours;
    ICovenRouter public immutable ROUTER;
    ICovenLens public immutable LENS;
    uint256 public immutable changeDelay;
    address public sessionKey;
    address public pendingSessionKey;
    uint40 public pendingSessionKeyAt;
    bool public revoked;
    mapping(bytes32 key => Gate gate) private _gate;
    mapping(address token => Window window) private _win;
    Window private _count;
    error NotSessionKey();
    error Revoked();
    error SessionExpired();
    error ZeroAmount();
    error InvalidTokens();
    error UsdcRequired();
    error TokenNotAllowed(address token);
    error NoRouteWithinImpact();
    error ZeroMinOut();
    error PerTradeCapExceeded(address token, uint256 amount, uint256 cap);
    error DailyCapExceeded(address token, uint256 total, uint256 cap);
    error TradeCountCapExceeded(uint256 count, uint256 cap);
    error InvalidConfig();
    error OwnershipCannotBeRenounced();
    event TradeExecuted(
        address indexed caller,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 expectedOut,
        uint256 minOut
    );
    event LimitChanged(uint256 indexed field, address indexed token, uint256 value);
    event LimitPending(uint256 indexed field, address indexed token, uint256 value, uint256 effectiveAt);
    event SessionKeyChanged(address indexed sessionKey);
    event SessionKeyPending(address indexed sessionKey, uint256 effectiveAt);
    event SessionRevoked();
    event Rescued(address indexed token, uint256 amount);
    constructor(address initialOwner, InitConfig memory cfg) Ownable(initialOwner) {
        if (cfg.router == address(0) || cfg.lens == address(0)) revert InvalidConfig();
        if (cfg.changeDelay < MIN_CHANGE_DELAY) revert InvalidConfig();
        if (cfg.maxImpactBps == 0 || cfg.maxImpactBps >= BPS) revert InvalidConfig();
        if (cfg.maxSlippageBps >= BPS) revert InvalidConfig();
        if (cfg.expiry <= block.timestamp) revert InvalidConfig();
        if (cfg.sessionKey == initialOwner) revert InvalidConfig();
        ROUTER = ICovenRouter(cfg.router);
        LENS = ICovenLens(cfg.lens);
        changeDelay = cfg.changeDelay;
        sessionKey = cfg.sessionKey;
        _gate[_g(EXPIRY)].cur = cfg.expiry;
        _gate[_g(COUNT)].cur = cfg.tradeCountCap;
        _gate[_g(IMPACT)].cur = cfg.maxImpactBps;
        _gate[_g(SLIPPAGE)].cur = cfg.maxSlippageBps;
        for (uint256 i; i < cfg.tokens.length; ++i) {
            TokenCap memory tc = cfg.tokens[i];
            if (tc.token == address(0)) revert InvalidConfig();
            _gate[_gt(tc.token, PER_TRADE)].cur = tc.perTradeCap;
            _gate[_gt(tc.token, DAILY)].cur = tc.dailyCap;
            emit LimitChanged(PER_TRADE, tc.token, tc.perTradeCap);
            emit LimitChanged(DAILY, tc.token, tc.dailyCap);
        }
        emit SessionKeyChanged(cfg.sessionKey);
    }
    function previewSwap(address tokenIn, address tokenOut, uint256 amountIn, PoolKey[] calldata extraPools)
        external
        returns (uint256 expectedOut, ICovenRouter.Hop[] memory hops)
    {
        uint16 impact = SafeCast.toUint16(_effective(_g(IMPACT)));
        uint256 gross;
        (hops, gross) = _route(tokenIn, tokenOut, amountIn, extraPools, impact);
        if (gross == 0 || hops.length == 0) return (0, hops);
        expectedOut = tokenOut == USDC ? gross - gross * ROUTER.platformFeeBps() / BPS : gross;
    }
    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        PoolKey[] calldata extraPools,
        uint256 expectedOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountOut) {
        _syncGlobals();
        _syncToken(tokenIn);
        if (revoked) revert Revoked();
        if (msg.sender != sessionKey && msg.sender != owner()) revert NotSessionKey();
        if (block.timestamp > _gate[_g(EXPIRY)].cur) revert SessionExpired();
        if (amountIn == 0) revert ZeroAmount();
        if (tokenIn == tokenOut) revert InvalidTokens();
        if (tokenIn != USDC && tokenOut != USDC) revert UsdcRequired();
        if (_gate[_gt(tokenIn, PER_TRADE)].cur == 0) revert TokenNotAllowed(tokenIn);
        if (_effective(_gt(tokenOut, PER_TRADE)) == 0) revert TokenNotAllowed(tokenOut);
        uint16 impact = SafeCast.toUint16(_gate[_g(IMPACT)].cur);
        (ICovenRouter.Hop[] memory hops, uint256 gross) = _route(tokenIn, tokenOut, amountIn, extraPools, impact);
        if (gross == 0 || hops.length == 0) revert NoRouteWithinImpact();
        uint256 netQuote = tokenOut == USDC ? gross - gross * ROUTER.platformFeeBps() / BPS : gross;
        uint256 floor = netQuote * (BPS - _gate[_g(SLIPPAGE)].cur) / BPS;
        uint256 minOut = expectedOut > floor ? expectedOut : floor;
        if (minOut == 0) revert ZeroMinOut();
        _accountCaps(tokenIn, amountIn);
        IERC20(tokenIn).safeTransferFrom(owner(), address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(ROUTER), amountIn);
        amountOut = ROUTER.swap(
            ICovenRouter.SwapParams({
                tokenIn: tokenIn,
                amountIn: amountIn,
                hops: hops,
                minAmountOut: minOut,
                deadline: deadline,
                integrator: address(0),
                integratorFeeBps: 0
            }),
            owner()
        );
        if (IERC20(tokenIn).allowance(address(this), address(ROUTER)) != 0) {
            IERC20(tokenIn).forceApprove(address(ROUTER), 0);
        }
        emit TradeExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut, expectedOut, minOut);
    }
    function setExpiry(uint40 value) external onlyOwner {
        _set(_g(EXPIRY), EXPIRY, address(0), value);
    }
    function setTradeCountCap(uint32 value) external onlyOwner {
        _set(_g(COUNT), COUNT, address(0), value);
    }
    function setMaxImpactBps(uint16 value) external onlyOwner {
        if (value == 0 || value >= BPS) revert InvalidConfig();
        _set(_g(IMPACT), IMPACT, address(0), value);
    }
    function setMaxSlippageBps(uint16 value) external onlyOwner {
        if (value >= BPS) revert InvalidConfig();
        _set(_g(SLIPPAGE), SLIPPAGE, address(0), value);
    }
    function setTokenCaps(address token, uint256 perTrade, uint256 daily) external onlyOwner {
        if (token == address(0)) revert InvalidConfig();
        _set(_gt(token, PER_TRADE), PER_TRADE, token, perTrade);
        _set(_gt(token, DAILY), DAILY, token, daily);
    }
    function revokeToken(address token) external onlyOwner {
        _set(_gt(token, PER_TRADE), PER_TRADE, token, 0);
        _set(_gt(token, DAILY), DAILY, token, 0);
    }
    function setSessionKey(address key) external onlyOwner {
        _syncSessionKey();
        if (key == address(0)) {
            sessionKey = address(0);
            pendingSessionKeyAt = 0;
            emit SessionKeyChanged(address(0));
        } else {
            pendingSessionKey = key;
            pendingSessionKeyAt = SafeCast.toUint40(block.timestamp + changeDelay);
            emit SessionKeyPending(key, block.timestamp + changeDelay);
        }
    }
    function revoke() external onlyOwner {
        revoked = true;
        emit SessionRevoked();
    }
    function rescue(IERC20 token, uint256 amount) external onlyOwner {
        token.safeTransfer(owner(), amount);
        emit Rescued(address(token), amount);
    }
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }
    function expiry() external view returns (uint256) {
        return _effective(_g(EXPIRY));
    }
    function tradeCountCap() external view returns (uint256) {
        return _effective(_g(COUNT));
    }
    function maxImpactBps() external view returns (uint256) {
        return _effective(_g(IMPACT));
    }
    function maxSlippageBps() external view returns (uint256) {
        return _effective(_g(SLIPPAGE));
    }
    function isAllowed(address token) external view returns (bool) {
        return _effective(_gt(token, PER_TRADE)) > 0;
    }
    function perTradeCap(address token) external view returns (uint256) {
        return _effective(_gt(token, PER_TRADE));
    }
    function dailyCap(address token) external view returns (uint256) {
        return _effective(_gt(token, DAILY));
    }
    function status()
        external
        view
        returns (
            uint256 expiry_,
            uint256 tradeCountCap_,
            uint256 tradesInWindow,
            uint256 maxImpactBps_,
            uint256 maxSlippageBps_,
            address sessionKey_,
            bool revoked_
        )
    {
        expiry_ = _effective(_g(EXPIRY));
        tradeCountCap_ = _effective(_g(COUNT));
        tradesInWindow = block.timestamp >= _count.start + WINDOW ? 0 : _count.spent;
        maxImpactBps_ = _effective(_g(IMPACT));
        maxSlippageBps_ = _effective(_g(SLIPPAGE));
        sessionKey_ = _effectiveSessionKey();
        revoked_ = revoked;
    }
    function tokenStatus(address token)
        external
        view
        returns (bool allowed, uint256 perTradeCap_, uint256 dailyCap_, uint256 spentToday, uint256 remainingToday)
    {
        perTradeCap_ = _effective(_gt(token, PER_TRADE));
        dailyCap_ = _effective(_gt(token, DAILY));
        allowed = perTradeCap_ > 0;
        Window storage w = _win[token];
        spentToday = block.timestamp >= w.start + WINDOW ? 0 : w.spent;
        remainingToday = dailyCap_ > spentToday ? dailyCap_ - spentToday : 0;
    }
    function _route(address tokenIn, address tokenOut, uint256 amountIn, PoolKey[] calldata extraPools, uint16 impact)
        internal
        returns (ICovenRouter.Hop[] memory hops, uint256 gross)
    {
        uint256 platformBps = ROUTER.platformFeeBps();
        uint256 swapIn = tokenOut == USDC ? amountIn : amountIn - amountIn * platformBps / BPS;
        (hops, gross) = LENS.quote(tokenIn, tokenOut, swapIn, _connectors(), extraPools, impact);
    }
    function _connectors() internal pure returns (address[] memory c) {
        c = new address[](2);
        c[0] = USDC;
        c[1] = EURC;
    }
    function _accountCaps(address token, uint256 amount) private {
        uint256 nowT = block.timestamp;
        if (nowT >= _count.start + WINDOW) {
            _count.start = SafeCast.toUint40(nowT);
            _count.spent = 0;
        }
        uint256 countCap = _gate[_g(COUNT)].cur;
        if (_count.spent + 1 > countCap) revert TradeCountCapExceeded(_count.spent + 1, countCap);
        Window storage w = _win[token];
        if (nowT >= w.start + WINDOW) {
            w.start = SafeCast.toUint40(nowT);
            w.spent = 0;
        }
        uint256 perTrade = _gate[_gt(token, PER_TRADE)].cur;
        uint256 daily = _gate[_gt(token, DAILY)].cur;
        if (amount > perTrade) revert PerTradeCapExceeded(token, amount, perTrade);
        if (w.spent + amount > daily) revert DailyCapExceeded(token, w.spent + amount, daily);
        w.spent += amount;
        _count.spent += 1;
    }
    function _set(bytes32 key, uint256 field, address token, uint256 value) private {
        _sync(key, field, token);
        Gate storage g = _gate[key];
        if (value <= g.cur) {
            g.cur = value;
            g.pendAt = 0;
            emit LimitChanged(field, token, value);
        } else {
            g.pend = value;
            g.pendAt = SafeCast.toUint40(block.timestamp + changeDelay);
            emit LimitPending(field, token, value, block.timestamp + changeDelay);
        }
    }
    function _sync(bytes32 key, uint256 field, address token) private {
        Gate storage g = _gate[key];
        if (g.pendAt != 0 && block.timestamp >= g.pendAt) {
            g.cur = g.pend;
            g.pendAt = 0;
            emit LimitChanged(field, token, g.pend);
        }
    }
    function _syncGlobals() private {
        _sync(_g(EXPIRY), EXPIRY, address(0));
        _sync(_g(COUNT), COUNT, address(0));
        _sync(_g(IMPACT), IMPACT, address(0));
        _sync(_g(SLIPPAGE), SLIPPAGE, address(0));
        _syncSessionKey();
    }
    function _syncToken(address token) private {
        _sync(_gt(token, PER_TRADE), PER_TRADE, token);
        _sync(_gt(token, DAILY), DAILY, token);
    }
    function _syncSessionKey() private {
        if (pendingSessionKeyAt != 0 && block.timestamp >= pendingSessionKeyAt) {
            sessionKey = pendingSessionKey;
            pendingSessionKeyAt = 0;
            emit SessionKeyChanged(pendingSessionKey);
        }
    }
    function _effective(bytes32 key) internal view returns (uint256) {
        Gate storage g = _gate[key];
        if (g.pendAt != 0 && block.timestamp >= g.pendAt) return g.pend;
        return g.cur;
    }
    function _effectiveSessionKey() internal view returns (address) {
        if (pendingSessionKeyAt != 0 && block.timestamp >= pendingSessionKeyAt) return pendingSessionKey;
        return sessionKey;
    }
    function _g(uint256 field) private pure returns (bytes32) {
        return bytes32(field);
    }
    function _gt(address token, uint256 field) private pure returns (bytes32) {
        return keccak256(abi.encode(token, field));
    }
}
