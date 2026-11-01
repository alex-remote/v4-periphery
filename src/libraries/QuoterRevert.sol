// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ParseBytes} from "@uniswap/v4-core/src/libraries/ParseBytes.sol";

library QuoterRevert {
    using QuoterRevert for bytes;
    using ParseBytes for bytes;

    /// @notice 报价过程抛出无效的 revert 字节时抛出的错误
    error UnexpectedRevertBytes(bytes revertData);

    /// @notice 以报价作为数据抛出的错误，供之后捕获并解析
    error QuoteSwap(uint256 amount);

    /// @notice 回滚（revert），回滚数据为所提供的字节
    /// @dev 在报价时调用，用于把报价数量记录在错误中
    /// @dev QuoteSwap 用于将此错误与模拟兑换（swap）时抛出的其它错误区分开
    function revertQuote(uint256 quoteAmount) internal pure {
        revert QuoteSwap(quoteAmount);
    }

    /// @notice 以 revertData 作为原因进行回滚（revert）
    /// @dev 用于向上冒泡传递有效的 QuoteSwap(amount) 错误，或模拟期间抛出的其它错误
    function bubbleReason(bytes memory revertData) internal pure {
        // mload(revertData): 回滚数据的长度
        // add(revertData, 0x20): 指向回滚数据起始位置的指针
        assembly ("memory-safe") {
            revert(add(revertData, 0x20), mload(revertData))
        }
    }

    /// @notice 校验回滚原因是否为有效的兑换（swap）报价
    /// 若有效，则解码出报价并返回；否则回滚（revert）。
    function parseQuoteAmount(bytes memory reason) internal pure returns (uint256 quoteAmount) {
        // 如果该错误不是以 QuoteSwap 开头，就说明它不是可解析的有效报价
        // 而是模拟过程中某处触发的其它 revert
        if (reason.parseSelector() != QuoteSwap.selector) {
            revert UnexpectedRevertBytes(reason);
        }

        // reason -> reason+0x1f 是 reason 字符串的长度
        // reason+0x20 -> reason+0x23 是 QuoteSwap 的选择器
        // reason+0x24 -> reason+0x43 是 quoteAmount
        assembly ("memory-safe") {
            quoteAmount := mload(add(reason, 0x24))
        }
    }
}
