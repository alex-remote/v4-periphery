// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title 操作（action）常量
/// @notice 各操作（action）中使用的通用常量
/// @dev 常量是对应字面值的节省 gas 的替代写法
library ActionConstants {
    /// @notice 用于表示某个操作（action）应使用 PoolManager 上未结清 delta（open delta）的值作为输入
    /// 或使用合约所持有的余额
    uint128 internal constant OPEN_DELTA = 0;
    /// @notice 用于表示某个操作（action）应使用合约持有的某种代币的全部余额
    /// 该值等于 1<<255，即仅最高有效位为 1。
    uint256 internal constant CONTRACT_BALANCE = 0x8000000000000000000000000000000000000000000000000000000000000000;

    /// @notice 用于表示某个操作（action）的接收者应为 msgSender
    address internal constant MSG_SENDER = address(1);

    /// @notice 用于表示某个操作（action）的接收者应为 address(this)
    address internal constant ADDRESS_THIS = address(2);
}
