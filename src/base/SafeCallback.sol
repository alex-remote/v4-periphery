// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ImmutableState} from "./ImmutableState.sol";

/// @title 安全回调（Safe Callback）
/// @notice 仅允许 Uniswap v4 PoolManager 调用 unlockCallback 的合约
abstract contract SafeCallback is ImmutableState, IUnlockCallback {
    constructor(IPoolManager _poolManager) ImmutableState(_poolManager) {}

    /// @inheritdoc IUnlockCallback
    /// @dev 通过在 onlyPoolManager 检查之后才暴露一个 virtual 函数，来强制应用 onlyPoolManager 修饰器。
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        return _unlockCallback(data);
    }

    /// @dev 由子合约实现，以安全地保证该逻辑只会由 PoolManager 执行
    function _unlockCallback(bytes calldata data) internal virtual returns (bytes memory);
}
