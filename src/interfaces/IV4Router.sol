// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PathKey} from "../libraries/PathKey.sol";
import {IImmutableState} from "./IImmutableState.sol";

/// @title IV4Router
/// @notice V4Router 合约的接口
interface IV4Router is IImmutableState {
    /// @notice 当 exactInput 兑换收到的数量未达到其 minAmountOut 时抛出
    error V4TooLittleReceived(uint256 minAmountOutReceived, uint256 amountReceived);
    /// @notice 当 exactOutput 被要求支付的数量超过其 maxAmountIn 时抛出
    error V4TooMuchRequested(uint256 maxAmountInRequested, uint256 amountRequested);
    /// @notice 当 exactInput 兑换未达到其相对的每跳（hop）minAmountOut（最低价格）时抛出
    error V4TooLittleReceivedPerHop(uint256 hopIndex, uint256 minPrice, uint256 price);
    /// @notice 当 exactOutput 被要求支付的数量超过其相对的每跳（hop）maxAmountIn（最低价格）时抛出
    error V4TooMuchRequestedPerHop(uint256 hopIndex, uint256 minPrice, uint256 price);
    /// @notice 当单跳 exactInput 兑换未满足其相对价格限制时抛出
    error V4TooLittleReceivedPerHopSingle(uint256 minPrice, uint256 price);
    /// @notice 当单跳 exactOutput 兑换超出其相对价格限制时抛出
    error V4TooMuchRequestedPerHopSingle(uint256 minPrice, uint256 price);
    /// @notice 当每跳最低价格数组的长度既不为零、也不等于路径长度时抛出
    error InvalidHopPriceLength();
    /// @notice 当 exactOutput 兑换（或某一跳）交付的数量少于请求数量时抛出，例如某个
    ///         池在达到价格限制之前流动性耗尽。精确输出是全有或全无（all-or-nothing）的。
    error V4ExactOutputUnfilled(uint256 amountOutRequested, uint256 amountOutReceived);

    /// @notice 单跳精确输入兑换的参数
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    /// @notice 多跳精确输入兑换的参数
    struct ExactInputParams {
        Currency currencyIn;
        PathKey[] path;
        uint256[] minHopPriceX36;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }

    /// @notice 单跳精确输出兑换的参数
    struct ExactOutputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountOut;
        uint128 amountInMaximum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    /// @notice 多跳精确输出兑换的参数
    struct ExactOutputParams {
        Currency currencyOut;
        PathKey[] path;
        uint256[] minHopPriceX36;
        uint128 amountOut;
        uint128 amountInMaximum;
    }
}
