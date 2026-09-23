// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ISwapRouter02} from "../../src/interfaces/external/IUniswapV3.sol";
import {ITokenMessengerV2} from "../../src/interfaces/external/ITokenMessengerV2.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external virtual returns (bool) {
        _transfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        _transfer(from, to, amt);
        return true;
    }

    function _transfer(address from, address to, uint256 amt) internal {
        require(balanceOf[from] >= amt, "balance");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
    }
}

/// Deterministic 1:1 (or rate-scaled) V3 router. Optionally consumes less input to
/// exercise the router's exact-fill guard.
contract MockSwapRouter02 is ISwapRouter02 {
    uint256 public rateBps = 10_000; // output = input * rateBps / 10_000
    bool public consumeLess;         // if true, pulls amountIn-1 (partial fill)

    function setRate(uint256 bps) external {
        rateBps = bps;
    }

    function setConsumeLess(bool v) external {
        consumeLess = v;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        uint256 pull = consumeLess ? p.amountIn - 1 : p.amountIn;
        require(MockERC20(p.tokenIn).transferFrom(msg.sender, address(this), pull), "tf");
        amountOut = p.amountIn * rateBps / 10_000;
        MockERC20(p.tokenOut).mint(p.recipient, amountOut);
    }
}

/// Minimal v4 PoolManager honoring the router's unlock/swap/sync/settle/take dance.
contract MockPoolManager {
    uint256 public rateBps = 10_000;
    bool public underfillInput; // return |deltaIn| < amountIn to trigger PartialFill
    bool public zeroOutput;     // return deltaOut == 0 to trigger ZeroAmount

    function setRate(uint256 bps) external {
        rateBps = bps;
    }

    function setUnderfillInput(bool v) external {
        underfillInput = v;
    }

    function setZeroOutput(bool v) external {
        zeroOutput = v;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(PoolKey calldata, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        view
        returns (BalanceDelta)
    {
        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 amountOut = zeroOutput ? 0 : amountIn * rateBps / 10_000;
        uint256 reportedIn = underfillInput ? amountIn - 1 : amountIn;
        int128 inDelta = -SafeCast.toInt128(SafeCast.toInt256(reportedIn));
        int128 outDelta = SafeCast.toInt128(SafeCast.toInt256(amountOut));
        // token0 is currency0; zeroForOne => pay token0, receive token1
        if (params.zeroForOne) {
            return toBalanceDelta(inDelta, outDelta);
        } else {
            return toBalanceDelta(outDelta, inDelta);
        }
    }

    function sync(Currency) external {}

    function settle() external payable returns (uint256) {
        return 0;
    }

    function take(Currency currency, address to, uint256 amount) external {
        MockERC20(Currency.unwrap(currency)).mint(to, amount);
    }
}

/// ERC20 that attempts to reenter an arbitrary target during transfer.
contract ReentrantToken is MockERC20 {
    address public target;
    bytes public reentryData;
    bool public armed;

    constructor() MockERC20("Reentrant", "RE") {}

    function arm(address t, bytes calldata data) external {
        require(t != address(0), "zero");
        target = t;
        reentryData = data;
        armed = true;
    }

    function transfer(address to, uint256 amt) public override returns (bool) {
        if (armed) {
            armed = false; // fire once
            (bool ok, bytes memory ret) = target.call(reentryData);
            if (!ok) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        _transfer(msg.sender, to, amt);
        return true;
    }
}

contract MockTokenMessenger is ITokenMessengerV2 {
    address public constant USDC = 0x3600000000000000000000000000000000000000;

    uint256 public lastAmount;
    uint32 public lastDomain;
    bytes32 public lastRecipient;
    bytes public lastHookData;
    bool public hookPathUsed;

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address,
        bytes32,
        uint256,
        uint32
    ) external {
        require(MockERC20(USDC).transferFrom(msg.sender, address(this), amount), "tf");
        lastAmount = amount;
        lastDomain = destinationDomain;
        lastRecipient = mintRecipient;
        hookPathUsed = false;
    }

    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address,
        bytes32,
        uint256,
        uint32,
        bytes calldata hookData
    ) external {
        require(MockERC20(USDC).transferFrom(msg.sender, address(this), amount), "tf");
        lastAmount = amount;
        lastDomain = destinationDomain;
        lastRecipient = mintRecipient;
        lastHookData = hookData;
        hookPathUsed = true;
    }
}
