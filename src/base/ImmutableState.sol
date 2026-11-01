// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IImmutableState} from "../interfaces/IImmutableState.sol";

/// @title 不可变状态（Immutable State）
/// @notice 一组 immutable 状态变量，通常在多个合约之间共用
contract ImmutableState is IImmutableState {
    /// @inheritdoc IImmutableState
    IPoolManager public immutable poolManager;

    /// @notice 当调用者不是 PoolManager 时抛出
    error NotPoolManager();

    /// @notice 仅允许来自 PoolManager 合约的调用
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }
}
