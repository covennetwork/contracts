// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
interface ICovenRouter {
    enum Protocol {
        V3,
        V4
    }
    struct Hop {
        Protocol protocol;
        address tokenOut;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }
    struct SwapParams {
        address tokenIn;
        uint256 amountIn;
        Hop[] hops;
        uint256 minAmountOut;
        uint256 deadline;
        address integrator;
        uint16 integratorFeeBps;
    }
    struct BridgeParams {
        uint32 destinationDomain;
        bytes32 mintRecipient;
        bytes32 destinationCaller;
        uint256 maxFee;
        uint32 minFinalityThreshold;
        bytes hookData;
    }
    event Swapped(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address feeToken,
        uint256 platformFee,
        address integrator,
        uint256 integratorFee
    );
    event Bridged(
        address indexed sender, uint32 indexed destinationDomain, bytes32 indexed mintRecipient, uint256 amount, uint256 maxFee
    );
    event PlatformFeeUpdated(uint16 feeBps);
    event FeeRecipientUpdated(address indexed feeRecipient);
    event GuardianUpdated(address indexed guardian);
    event HookAllowedUpdated(address indexed hook, bool allowed);
    event HookTemplateAdded(bytes32 indexed templateId, address indexed referenceHook, uint256 codeSize);
    event HookTemplateRemoved(bytes32 indexed templateId);
    event Swept(address indexed token, address indexed to, uint256 amount);
    error Expired();
    error InvalidPath();
    error InvalidRecipient();
    error InvalidDestination();
    error InvalidIntegratorFee();
    error InvalidPlatformFee();
    error InvalidFeeRecipient();
    error InvalidGuardian();
    error InvalidHook();
    error InvalidTemplate();
    error TemplateExists();
    error TemplateNotFound();
    error TooManyTemplates();
    error ZeroAmount();
    error ZeroMinAmountOut();
    error PartialFill();
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    error BridgeRequiresUsdc();
    error HookNotAllowed(address hook);
    error Unauthorized();
    error OwnershipCannotBeRenounced();
    function swap(SwapParams calldata params, address recipient) external returns (uint256 amountOut);
    function swapAndBridge(SwapParams calldata params, BridgeParams calldata bridge) external returns (uint256 amountOut);
    function isHookAllowed(address hook) external view returns (bool);
    function platformFeeBps() external view returns (uint16);
    function feeRecipient() external view returns (address);
}
