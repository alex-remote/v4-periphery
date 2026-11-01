// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IMsgSender} from "../../../../src/interfaces/IMsgSender.sol";

/// @notice 一个不在适配器 `allowedWrappers` 列表中的 wrapper（包装合约）。
/// @dev 返回一个持有所需权限标志的 `msgSender`，从而可以把回滚归因于 wrapper
///      检查而非权限检查。没有 `msgSender()` 的 wrapper 会更早被拒绝（在
///      hook 的 staticcall 阶段），那样什么也证明不了。
contract MockUnapprovedWrapper is PoolSwapTest, IMsgSender {
    address private immutable SENDER;

    constructor(IPoolManager manager_, address sender_) PoolSwapTest(manager_) {
        SENDER = sender_;
    }

    /// @inheritdoc IMsgSender
    function msgSender() external view returns (address) {
        return SENDER;
    }
}
