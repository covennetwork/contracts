// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
interface IV4Quoter {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }
    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}
