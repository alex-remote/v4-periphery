// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PathKey} from "../libraries/PathKey.sol";
import {IImmutableState} from "./IImmutableState.sol";
import {IMsgSender} from "./IMsgSender.sol";

/// @title IV4Quoter
/// @notice V4Quoter 合约的接口
interface IV4Quoter is IImmutableState, IMsgSender {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    struct QuoteExactParams {
        Currency exactCurrency;
        PathKey[] path;
        uint128 exactAmount;
    }

    /// @notice 返回单个池中给定精确输入兑换（swap）的 delta 数量
    /// @param params 报价参数，编码为 `QuoteExactSingleParams`
    /// poolKey 用于标识 V4 池的 key
    /// zeroForOne 兑换是否从 currency0 到 currency1
    /// exactAmount 期望的输入数量
    /// hookData 传递给关联 hook 的任意 hookData
    /// @return amountOut exactIn 兑换的输出报价
    /// @return gasEstimate 该兑换预计消耗的 gas 单位数
    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);

    /// @notice 返回给定精确输入兑换沿兑换路径的各 delta 数量
    /// @param params 报价参数，编码为 'QuoteExactParams'
    /// currencyIn 兑换的输入代币
    /// path 兑换路径，编码为 PathKeys，包含代币、手续费、tickSpacing 和 hook 信息
    /// exactAmount 期望的输入数量
    /// @return amountOut exactIn 兑换的输出报价
    /// @return gasEstimate 该兑换预计消耗的 gas 单位数
    function quoteExactInput(QuoteExactParams memory params) external returns (uint256 amountOut, uint256 gasEstimate);

    /// @notice 返回单个池中给定精确输出兑换（swap）的 delta 数量
    /// @param params 报价参数，编码为 `QuoteExactSingleParams`
    /// poolKey 用于标识 V4 池的 key
    /// zeroForOne 兑换是否从 currency0 到 currency1
    /// exactAmount 期望的输出数量
    /// hookData 传递给关联 hook 的任意 hookData
    /// @return amountIn exactOut 兑换的输入报价
    /// @return gasEstimate 该兑换预计消耗的 gas 单位数
    function quoteExactOutputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountIn, uint256 gasEstimate);

    /// @notice 返回给定精确输出兑换沿兑换路径的各 delta 数量
    /// @param params 报价参数，编码为 'QuoteExactParams'
    /// currencyOut 兑换的输出代币
    /// path 兑换路径，编码为 PathKeys，包含代币、手续费、tickSpacing 和 hook 信息
    /// exactAmount 期望的输出数量
    /// @return amountIn exactOut 兑换的输入报价
    /// @return gasEstimate 该兑换预计消耗的 gas 单位数
    function quoteExactOutput(QuoteExactParams memory params) external returns (uint256 amountIn, uint256 gasEstimate);
}
