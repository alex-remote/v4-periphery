// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IMsgSender
/// @notice 对外暴露原始调用者的合约所实现的接口
interface IMsgSender {
    /// @notice 返回原始调用者（msg.sender）的地址
    /// @dev Uniswap v4 periphery 合约采用回调模式，这会丢失
    /// 原始 msg.sender 调用者的上下文。该 view 函数为
    /// 集成合约（例如 hook）提供了一种获取原始调用者地址的方式。
    /// @return 原始调用者的地址
    function msgSender() external view returns (address);
}
