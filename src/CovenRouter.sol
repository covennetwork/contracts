// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ICovenRouter} from "./interfaces/ICovenRouter.sol";
import {ISwapRouter02} from "./interfaces/external/IUniswapV3.sol";
import {ITokenMessengerV2} from "./interfaces/external/ITokenMessengerV2.sol";
contract CovenRouter is ICovenRouter, IUnlockCallback, Ownable2Step, Pausable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    struct HookTemplate {
        uint256 codeSize;
        uint16[] maskOffsets;
    }
    address public constant USDC = 0x3600000000000000000000000000000000000000;
    IPoolManager public constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    ISwapRouter02 public constant SWAP_ROUTER_02 = ISwapRouter02(0x53BF6B0684Ec7eF91e1387Da3D1a1769bC5A6F77);
    ITokenMessengerV2 public constant TOKEN_MESSENGER = ITokenMessengerV2(0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d);
    uint32 public constant LOCAL_DOMAIN = 26;
    uint16 public constant MAX_PLATFORM_FEE_BPS = 100;
    uint16 public constant MAX_INTEGRATOR_FEE_BPS = 300;
    uint256 public constant MAX_HOPS = 4;
    uint256 public constant MAX_HOOK_TEMPLATES = 8;
    uint160 public constant SWAP_HOOK_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint16 private constant BPS = 10_000;
    uint16 public platformFeeBps;
    address public feeRecipient;
    address public guardian;
    mapping(address hook => bool allowed) public hookAllowed;
    bytes32[] private _templateIds;
    mapping(bytes32 templateId => HookTemplate template) private _templates;
    constructor(address initialOwner, address initialFeeRecipient, address initialGuardian, uint16 initialPlatformFeeBps)
        Ownable(initialOwner)
    {
        _setFeeRecipient(initialFeeRecipient);
        _setPlatformFee(initialPlatformFeeBps);
        _setGuardian(initialGuardian);
    }
    function swap(SwapParams calldata params, address recipient)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amountOut)
    {
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        address tokenOut;
        (tokenOut, amountOut) = _swap(params);
        IERC20(tokenOut).safeTransfer(recipient, amountOut);
    }
    function swapAndBridge(SwapParams calldata params, BridgeParams calldata bridge)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amountOut)
    {
        if (bridge.destinationDomain == LOCAL_DOMAIN) revert InvalidDestination();
        if (bridge.mintRecipient == bytes32(0)) revert InvalidRecipient();
        address tokenOut;
        (tokenOut, amountOut) = _swap(params);
        if (tokenOut != USDC) revert BridgeRequiresUsdc();
        IERC20(USDC).forceApprove(address(TOKEN_MESSENGER), amountOut);
        if (bridge.hookData.length == 0) {
            TOKEN_MESSENGER.depositForBurn(
                amountOut,
                bridge.destinationDomain,
                bridge.mintRecipient,
                USDC,
                bridge.destinationCaller,
                bridge.maxFee,
                bridge.minFinalityThreshold
            );
        } else {
            TOKEN_MESSENGER.depositForBurnWithHook(
                amountOut,
                bridge.destinationDomain,
                bridge.mintRecipient,
                USDC,
                bridge.destinationCaller,
                bridge.maxFee,
                bridge.minFinalityThreshold,
                bridge.hookData
            );
        }
        if (IERC20(USDC).allowance(address(this), address(TOKEN_MESSENGER)) != 0) {
            IERC20(USDC).forceApprove(address(TOKEN_MESSENGER), 0);
        }
        emit Bridged(msg.sender, bridge.destinationDomain, bridge.mintRecipient, amountOut, bridge.maxFee);
    }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert Unauthorized();
        (PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));
        BalanceDelta delta = POOL_MANAGER.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -SafeCast.toInt256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (int128 deltaIn, int128 deltaOut, Currency currencyIn, Currency currencyOut) = zeroForOne
            ? (delta.amount0(), delta.amount1(), key.currency0, key.currency1)
            : (delta.amount1(), delta.amount0(), key.currency1, key.currency0);
        if (deltaIn >= 0 || SafeCast.toUint256(-int256(deltaIn)) != amountIn) revert PartialFill();
        if (deltaOut <= 0) revert ZeroAmount();
        POOL_MANAGER.sync(currencyIn);
        IERC20(Currency.unwrap(currencyIn)).safeTransfer(address(POOL_MANAGER), amountIn);
        POOL_MANAGER.settle();
        POOL_MANAGER.take(currencyOut, address(this), SafeCast.toUint256(int256(deltaOut)));
        return "";
    }
    function isHookAllowed(address hook) public view returns (bool) {
        if (hookAllowed[hook]) return true;
        uint256 count = _templateIds.length;
        if (count == 0) return false;
        bytes memory code = hook.code;
        if (code.length == 0) return false;
        for (uint256 i; i < count; ++i) {
            bytes32 id = _templateIds[i];
            HookTemplate storage template = _templates[id];
            if (template.codeSize == code.length && _maskedCodeHash(code, template.maskOffsets) == id) return true;
        }
        return false;
    }
    function hookTemplateIds() external view returns (bytes32[] memory) {
        return _templateIds;
    }
    function hookTemplate(bytes32 templateId) external view returns (uint256 codeSize, uint16[] memory maskOffsets) {
        HookTemplate storage template = _templates[templateId];
        return (template.codeSize, template.maskOffsets);
    }
    function pause() external {
        if (msg.sender != owner() && msg.sender != guardian) revert Unauthorized();
        _pause();
    }
    function unpause() external onlyOwner {
        _unpause();
    }
    function setPlatformFee(uint16 feeBps) external onlyOwner {
        _setPlatformFee(feeBps);
    }
    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        _setFeeRecipient(newFeeRecipient);
    }
    function setGuardian(address newGuardian) external onlyOwner {
        _setGuardian(newGuardian);
    }
    function setHookAllowed(address hook, bool allowed) external onlyOwner {
        if (hook == address(0)) revert InvalidHook();
        hookAllowed[hook] = allowed;
        emit HookAllowedUpdated(hook, allowed);
    }
    function addHookTemplate(address referenceHook, uint16[] calldata maskOffsets)
        external
        onlyOwner
        returns (bytes32 templateId)
    {
        if (_templateIds.length >= MAX_HOOK_TEMPLATES) revert TooManyTemplates();
        bytes memory code = referenceHook.code;
        uint256 size = code.length;
        if (size == 0) revert InvalidTemplate();
        uint256 minNext;
        for (uint256 i; i < maskOffsets.length; ++i) {
            uint256 offset = maskOffsets[i];
            if (offset < minNext || offset + 32 > size) revert InvalidTemplate();
            minNext = offset + 32;
        }
        templateId = _maskedCodeHash(code, maskOffsets);
        if (_templates[templateId].codeSize != 0) revert TemplateExists();
        _templates[templateId] = HookTemplate({codeSize: size, maskOffsets: maskOffsets});
        _templateIds.push(templateId);
        emit HookTemplateAdded(templateId, referenceHook, size);
    }
    function removeHookTemplate(bytes32 templateId) external onlyOwner {
        uint256 count = _templateIds.length;
        for (uint256 i; i < count; ++i) {
            if (_templateIds[i] == templateId) {
                _templateIds[i] = _templateIds[count - 1];
                _templateIds.pop();
                delete _templates[templateId];
                emit HookTemplateRemoved(templateId);
                return;
            }
        }
        revert TemplateNotFound();
    }
    function sweep(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
        token.safeTransfer(to, amount);
        emit Swept(address(token), to, amount);
    }
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }
    function _swap(SwapParams calldata params) private returns (address tokenOut, uint256 amountOut) {
        if (block.timestamp > params.deadline) revert Expired();
        if (params.minAmountOut == 0) revert ZeroMinAmountOut();
        uint256 hopCount = params.hops.length;
        if (hopCount == 0 || hopCount > MAX_HOPS) revert InvalidPath();
        if (
            params.integratorFeeBps > MAX_INTEGRATOR_FEE_BPS || params.integrator == address(this)
                || (params.integrator == address(0) && params.integratorFeeBps != 0)
        ) revert InvalidIntegratorFee();
        address tokenIn = params.tokenIn;
        tokenOut = params.hops[hopCount - 1].tokenOut;
        bool feeOnOutput = tokenOut == USDC && tokenIn != USDC;
        uint256 amount = _pull(tokenIn, params.amountIn);
        uint256 platformFee;
        uint256 integratorFee;
        if (!feeOnOutput) {
            (platformFee, integratorFee) = _chargeFees(tokenIn, amount, params.integrator, params.integratorFeeBps);
            amount -= platformFee + integratorFee;
        }
        address current = tokenIn;
        for (uint256 i; i < hopCount; ++i) {
            amount = _hop(current, params.hops[i], amount);
            current = params.hops[i].tokenOut;
        }
        if (feeOnOutput) {
            (platformFee, integratorFee) = _chargeFees(tokenOut, amount, params.integrator, params.integratorFeeBps);
            amount -= platformFee + integratorFee;
        }
        if (amount < params.minAmountOut) revert InsufficientOutput(amount, params.minAmountOut);
        amountOut = amount;
        emit Swapped(
            msg.sender,
            tokenIn,
            tokenOut,
            params.amountIn,
            amountOut,
            feeOnOutput ? tokenOut : tokenIn,
            platformFee,
            params.integrator,
            integratorFee
        );
    }
    function _hop(address tokenIn, Hop calldata hop, uint256 amountIn) private returns (uint256 amountOut) {
        address tokenOut = hop.tokenOut;
        if (amountIn == 0) revert ZeroAmount();
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut) revert InvalidPath();
        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));
        if (hop.protocol == Protocol.V3) {
            if (hop.tickSpacing != 0 || hop.hooks != address(0)) revert InvalidPath();
            IERC20(tokenIn).forceApprove(address(SWAP_ROUTER_02), amountIn);
            SWAP_ROUTER_02.exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: hop.fee,
                    recipient: address(this),
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
            if (IERC20(tokenIn).allowance(address(this), address(SWAP_ROUTER_02)) != 0) {
                IERC20(tokenIn).forceApprove(address(SWAP_ROUTER_02), 0);
            }
        } else {
            if (uint160(hop.hooks) & SWAP_HOOK_FLAGS != 0 && !isHookAllowed(hop.hooks)) {
                revert HookNotAllowed(hop.hooks);
            }
            bool zeroForOne = tokenIn < tokenOut;
            (address token0, address token1) = zeroForOne ? (tokenIn, tokenOut) : (tokenOut, tokenIn);
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(token0),
                currency1: Currency.wrap(token1),
                fee: hop.fee,
                tickSpacing: hop.tickSpacing,
                hooks: IHooks(hop.hooks)
            });
            POOL_MANAGER.unlock(abi.encode(key, zeroForOne, amountIn));
        }
        if (inBefore - IERC20(tokenIn).balanceOf(address(this)) != amountIn) revert PartialFill();
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        if (amountOut == 0) revert ZeroAmount();
    }
    function _pull(address token, uint256 amount) private returns (uint256 received) {
        if (amount == 0) revert ZeroAmount();
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - before;
    }
    function _chargeFees(address token, uint256 amount, address integrator, uint16 integratorFeeBps)
        private
        returns (uint256 platformFee, uint256 integratorFee)
    {
        platformFee = amount * platformFeeBps / BPS;
        integratorFee = amount * integratorFeeBps / BPS;
        if (platformFee != 0) IERC20(token).safeTransfer(feeRecipient, platformFee);
        if (integratorFee != 0) IERC20(token).safeTransfer(integrator, integratorFee);
    }
    function _setPlatformFee(uint16 feeBps) private {
        if (feeBps > MAX_PLATFORM_FEE_BPS) revert InvalidPlatformFee();
        platformFeeBps = feeBps;
        emit PlatformFeeUpdated(feeBps);
    }
    function _setFeeRecipient(address newFeeRecipient) private {
        if (newFeeRecipient == address(0) || newFeeRecipient == address(this)) revert InvalidFeeRecipient();
        feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(newFeeRecipient);
    }
    function _setGuardian(address newGuardian) private {
        if (newGuardian == address(0)) revert InvalidGuardian();
        guardian = newGuardian;
        emit GuardianUpdated(newGuardian);
    }
    function _maskedCodeHash(bytes memory code, uint16[] memory maskOffsets) private pure returns (bytes32 hash) {
        bytes memory masked = bytes.concat(code);
        for (uint256 i; i < maskOffsets.length; ++i) {
            uint256 offset = maskOffsets[i];
            assembly ("memory-safe") {
                mstore(add(add(masked, 0x20), offset), 0)
            }
        }
        hash = keccak256(masked);
    }
}
