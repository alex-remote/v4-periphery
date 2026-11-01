// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IV4Quoter} from "../interfaces/IV4Quoter.sol";
import {PathKey} from "../libraries/PathKey.sol";
import {QuoterRevert} from "../libraries/QuoterRevert.sol";
import {BaseV4Quoter} from "../base/BaseV4Quoter.sol";
import {Locker} from "../libraries/Locker.sol";
import {IMsgSender} from "../interfaces/IMsgSender.sol";

/// @title V4Quoter
/// @notice 支持为精确输入或精确输出的兑换（swap）报价 delta 数量。
/// @dev 这些函数没有标记为 view，因为它们依赖调用非 view 函数并回滚（revert）
/// 来计算结果。它们的 gas 效率也不高，不应在链上调用。
contract V4Quoter is IV4Quoter, BaseV4Quoter {
    using QuoterRevert for *;

    constructor(IPoolManager _poolManager) BaseV4Quoter(_poolManager) {}

    modifier setMsgSender() {
        Locker.set(msg.sender);
        _; // 执行函数
        Locker.set(address(0)); // 重置锁定者
    }

    /// @inheritdoc IV4Quoter
    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        setMsgSender
        returns (uint256 amountOut, uint256 gasEstimate)
    {
        uint256 gasBefore = gasleft();
        try poolManager.unlock(abi.encodeCall(this._quoteExactInputSingle, (params))) {}
        catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            // 从 QuoteSwap 错误中提取报价，若报价失败则抛出错误
            amountOut = reason.parseQuoteAmount();
        }
    }

    /// @inheritdoc IV4Quoter
    function quoteExactInput(QuoteExactParams memory params)
        external
        setMsgSender
        returns (uint256 amountOut, uint256 gasEstimate)
    {
        uint256 gasBefore = gasleft();
        try poolManager.unlock(abi.encodeCall(this._quoteExactInput, (params))) {}
        catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            // 从 QuoteSwap 错误中提取报价，若报价失败则抛出错误
            amountOut = reason.parseQuoteAmount();
        }
    }

    /// @inheritdoc IV4Quoter
    function quoteExactOutputSingle(QuoteExactSingleParams memory params)
        external
        setMsgSender
        returns (uint256 amountIn, uint256 gasEstimate)
    {
        uint256 gasBefore = gasleft();
        try poolManager.unlock(abi.encodeCall(this._quoteExactOutputSingle, (params))) {}
        catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            // 从 QuoteSwap 错误中提取报价，若报价失败则抛出错误
            amountIn = reason.parseQuoteAmount();
        }
    }

    /// @inheritdoc IV4Quoter
    function quoteExactOutput(QuoteExactParams memory params)
        external
        setMsgSender
        returns (uint256 amountIn, uint256 gasEstimate)
    {
        uint256 gasBefore = gasleft();
        try poolManager.unlock(abi.encodeCall(this._quoteExactOutput, (params))) {}
        catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            // 从 QuoteSwap 错误中提取报价，若报价失败则抛出错误
            amountIn = reason.parseQuoteAmount();
        }
    }

    /// @dev 在 _unlockCallback 中调用的 external 函数，用于模拟一次精确输入兑换（swap），然后携带结果回滚（revert）
    function _quoteExactInput(QuoteExactParams calldata params) external selfOnly returns (bytes memory) {
        uint256 pathLength = params.path.length;
        BalanceDelta swapDelta;
        uint128 amountIn = params.exactAmount;
        Currency inputCurrency = params.exactCurrency;
        PathKey calldata pathKey;

        for (uint256 i = 0; i < pathLength; i++) {
            pathKey = params.path[i];
            (PoolKey memory poolKey, bool zeroForOne) = pathKey.getPoolAndSwapDirection(inputCurrency);

            swapDelta = _swap(poolKey, zeroForOne, -int256(int128(amountIn)), pathKey.hookData);

            amountIn = zeroForOne ? uint128(swapDelta.amount1()) : uint128(swapDelta.amount0());
            inputCurrency = pathKey.intermediateCurrency;
        }
        // 循环结束后 amountIn 实际保存的是这笔交易的 amountOut
        amountIn.revertQuote();
    }

    /// @dev 在 _unlockCallback 中调用的 external 函数，用于模拟一次单跳精确输入兑换（swap），然后携带结果回滚（revert）
    function _quoteExactInputSingle(QuoteExactSingleParams calldata params) external selfOnly returns (bytes memory) {
        BalanceDelta swapDelta =
            _swap(params.poolKey, params.zeroForOne, -int256(int128(params.exactAmount)), params.hookData);

        // 兑换（swap）的输出 delta 为正
        uint256 amountOut = params.zeroForOne ? uint128(swapDelta.amount1()) : uint128(swapDelta.amount0());
        amountOut.revertQuote();
    }

    /// @dev 在 _unlockCallback 中调用的 external 函数，用于模拟一次精确输出兑换（swap），然后携带结果回滚（revert）
    function _quoteExactOutput(QuoteExactParams calldata params) external selfOnly returns (bytes memory) {
        uint256 pathLength = params.path.length;
        BalanceDelta swapDelta;
        uint128 amountOut = params.exactAmount;
        Currency outputCurrency = params.exactCurrency;
        PathKey calldata pathKey;

        for (uint256 i = pathLength; i > 0; i--) {
            pathKey = params.path[i - 1];
            (PoolKey memory poolKey, bool oneForZero) = pathKey.getPoolAndSwapDirection(outputCurrency);

            swapDelta = _swap(poolKey, !oneForZero, int256(uint256(amountOut)), pathKey.hookData);

            amountOut = oneForZero ? uint128(-swapDelta.amount1()) : uint128(-swapDelta.amount0());

            outputCurrency = pathKey.intermediateCurrency;
        }
        // 循环退出后 amountOut 实际保存的是这笔交易的 amountIn
        amountOut.revertQuote();
    }

    /// @dev 在 _unlockCallback 中调用的 external 函数，用于模拟一次单跳精确输出兑换（swap），然后携带结果回滚（revert）
    function _quoteExactOutputSingle(QuoteExactSingleParams calldata params) external selfOnly returns (bytes memory) {
        BalanceDelta swapDelta =
            _swap(params.poolKey, params.zeroForOne, int256(uint256(params.exactAmount)), params.hookData);

        // 兑换（swap）的输入 delta 为负，因此必须取反
        uint256 amountIn = params.zeroForOne ? uint128(-swapDelta.amount0()) : uint128(-swapDelta.amount1());
        amountIn.revertQuote();
    }

    /// @inheritdoc IMsgSender
    function msgSender() external view returns (address) {
        // 尽管使用了 Locker 库，V4Quoter 并没有重入锁
        return Locker.get();
    }
}
