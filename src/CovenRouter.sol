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
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ICovenRouter} from "./interfaces/ICovenRouter.sol";
import {ISwapRouter02} from "./interfaces/external/IUniswapV3.sol";
import {ITokenMessengerV2} from "./interfaces/external/ITokenMessengerV2.sol";
contract CovenRouter is ICovenRouter, IUnlockCallback, Ownable2Step, Pausable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using LPFeeLibrary for uint24;
    struct HookTemplate {
        uint256 codeSize;
        uint16 hookFlags;
        MaskWindow[] windows;
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
    mapping(address token => mapping(address recipient => uint256 amount)) public claimableFees;
    mapping(address token => uint256 amount) public totalClaimableFees;
    bytes32[] private _templateIds;
    mapping(bytes32 templateId => HookTemplate template) private _templates;
    constructor(
        address initialOwner,
        address initialFeeRecipient,
        address initialGuardian,
        uint16 initialPlatformFeeBps,
        address[] memory initialHooks,
        TemplateInit[] memory initialTemplates
    ) Ownable(initialOwner) {
        _setFeeRecipient(initialFeeRecipient);
        _setPlatformFee(initialPlatformFeeBps);
        _setGuardian(initialGuardian);
        for (uint256 i; i < initialHooks.length; ++i) {
            _setHookAllowed(initialHooks[i], true);
        }
        for (uint256 i; i < initialTemplates.length; ++i) {
            _addHookTemplate(initialTemplates[i].referenceHook, initialTemplates[i].windows);
        }
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
        uint16 flags = SafeCast.toUint16(uint256(uint160(hook) & Hooks.ALL_HOOK_MASK));
        for (uint256 i; i < count; ++i) {
            bytes32 id = _templateIds[i];
            HookTemplate storage template = _templates[id];
            if (
                template.codeSize == code.length && template.hookFlags == flags
                    && _maskedCodeHash(code, template.windows) == id
            ) return true;
        }
        return false;
    }
    function hookTemplateIds() external view returns (bytes32[] memory) {
        return _templateIds;
    }
    function hookTemplate(bytes32 templateId)
        external
        view
        returns (uint256 codeSize, uint16 hookFlags, MaskWindow[] memory windows)
    {
        HookTemplate storage template = _templates[templateId];
        return (template.codeSize, template.hookFlags, template.windows);
    }
    function claimFees(IERC20 token, address to) external returns (uint256 amount) {
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
        amount = claimableFees[address(token)][msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimableFees[address(token)][msg.sender] = 0;
        totalClaimableFees[address(token)] -= amount;
        token.safeTransfer(to, amount);
        emit FeeClaimed(address(token), msg.sender, to, amount);
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
        _setHookAllowed(hook, allowed);
    }
    function addHookTemplate(address referenceHook, MaskWindow[] calldata windows)
        external
        onlyOwner
        returns (bytes32 templateId)
    {
        return _addHookTemplate(referenceHook, windows);
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
        uint256 balance = token.balanceOf(address(this));
        uint256 reserved = totalClaimableFees[address(token)];
        uint256 free = balance > reserved ? balance - reserved : 0;
        if (amount > free) revert SweepExceedsFree(amount, free);
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
            if (_needsAllowlist(hop.hooks, hop.fee) && !isHookAllowed(hop.hooks)) {
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
        _payFee(token, feeRecipient, platformFee);
        _payFee(token, integrator, integratorFee);
    }
    function _payFee(address token, address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))))) return;
        claimableFees[token][to] += amount;
        totalClaimableFees[token] += amount;
        emit FeeAccrued(token, to, amount);
    }
    function _needsAllowlist(address hook, uint24 fee) private pure returns (bool) {
        return hook != address(0) && (uint160(hook) & SWAP_HOOK_FLAGS != 0 || fee.isDynamicFee());
    }
    function _setHookAllowed(address hook, bool allowed) private {
        if (hook == address(0)) revert InvalidHook();
        hookAllowed[hook] = allowed;
        emit HookAllowedUpdated(hook, allowed);
    }
    function _addHookTemplate(address referenceHook, MaskWindow[] memory windows)
        private
        returns (bytes32 templateId)
    {
        if (_templateIds.length >= MAX_HOOK_TEMPLATES) revert TooManyTemplates();
        bytes memory code = referenceHook.code;
        uint256 size = code.length;
        if (size == 0) revert InvalidTemplate();
        uint256 minNext;
        for (uint256 i; i < windows.length; ++i) {
            uint256 offset = windows[i].offset;
            uint256 length = windows[i].length;
            if (length == 0 || offset < minNext || offset + length > size) revert InvalidTemplate();
            minNext = offset + length;
        }
        _assertMasksCoverConstants(code, windows);
        templateId = _maskedCodeHash(code, windows);
        if (_templates[templateId].codeSize != 0) revert TemplateExists();
        uint16 flags = SafeCast.toUint16(uint256(uint160(referenceHook) & Hooks.ALL_HOOK_MASK));
        HookTemplate storage template = _templates[templateId];
        template.codeSize = size;
        template.hookFlags = flags;
        for (uint256 i; i < windows.length; ++i) {
            template.windows.push(windows[i]);
        }
        _templateIds.push(templateId);
        emit HookTemplateAdded(templateId, referenceHook, size, flags);
    }
    function _assertMasksCoverConstants(bytes memory code, MaskWindow[] memory windows) private pure {
        uint256 size = code.length;
        bytes memory isImmediate = new bytes(size);
        uint256 pc;
        while (pc < size) {
            uint256 op = uint8(code[pc]);
            if (op >= 0x60 && op <= 0x7f) {
                uint256 n = op - 0x5f;
                for (uint256 k = 1; k <= n && pc + k < size; ++k) {
                    isImmediate[pc + k] = 0x01;
                }
                pc += 1 + n;
            } else {
                ++pc;
            }
        }
        for (uint256 i; i < windows.length; ++i) {
            uint256 offset = windows[i].offset;
            uint256 length = windows[i].length;
            for (uint256 k; k < length; ++k) {
                if (isImmediate[offset + k] == 0) revert MaskCoversCode(windows[i].offset);
            }
        }
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
    function _maskedCodeHash(bytes memory code, MaskWindow[] memory windows) private pure returns (bytes32 hash) {
        uint256 n = windows.length;
        bytes[] memory saved = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            uint256 offset = windows[i].offset;
            uint256 length = windows[i].length;
            bytes memory keep = new bytes(length);
            for (uint256 k; k < length; ++k) {
                keep[k] = code[offset + k];
                code[offset + k] = 0;
            }
            saved[i] = keep;
        }
        hash = keccak256(code);
        for (uint256 i; i < n; ++i) {
            uint256 offset = windows[i].offset;
            bytes memory keep = saved[i];
            for (uint256 k; k < keep.length; ++k) {
                code[offset + k] = keep[k];
            }
        }
    }
}
